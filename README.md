# GitHub Actions Self-Hosted Runners en Azure Container Apps
## Guía Completa: Desde Cero hasta Producción

Esta guía documenta la implementación completa de GitHub Actions self-hosted runners usando Azure Container Apps con Docker CLI y Azure CLI pre-instalados.

---

## 📋 Tabla de Contenidos

1. [Arquitectura](#arquitectura)
2. [Pre-requisitos](#pre-requisitos)
3. [Paso 1: Crear Recursos de Azure](#paso-1-crear-recursos-de-azure)
4. [Paso 2: Preparar Imagen del Runner](#paso-2-preparar-imagen-del-runner)
5. [Paso 3: Configurar GitHub](#paso-3-configurar-github)
6. [Paso 4: Desplegar Container Apps Job](#paso-4-desplegar-container-apps-job)
7. [Paso 5: Configurar KEDA Autoscaling](#paso-5-configurar-keda-autoscaling)
8. [Paso 6: Crear Workflow en GitHub](#paso-6-crear-workflow-en-github)
9. [Mejores Prácticas](#mejores-prácticas)
10. [Troubleshooting](#troubleshooting)

**Guías adicionales:**
- 📄 [Agregar un nuevo repo al runner existente](ADD-REPO.md) — Free/Team, environment ya funcionando
- 🏢 [GitHub Team/Enterprise: Runner Groups](ENTERPRISE.md) — un job para toda la organización (disponible desde GitHub Team/"Business")

---

## Arquitectura

```
GitHub Workflow Queue
        ↓
    [KEDA Scaler]
        ↓
Azure Container Apps Job (0-10 replicas)
        ↓
[Ephemeral Runners]
    ├── .NET SDK (via setup-dotnet action)
    ├── Docker CLI + GitHub CLI (gh)
    ├── Azure CLI (opcional)
    └── Custom tools
```

**Características:**
- ✅ Autoscaling 0-N basado en queue de workflows
- ✅ Runners efímeros (se destruyen después de cada job)
- ✅ VNet integration para acceso a recursos privados
- ✅ Docker CLI, GitHub CLI (gh) y Azure CLI pre-instalados en la imagen

---

## Pre-requisitos

### Software Necesario

- **Azure CLI**: >= 2.50.0
  ```bash
  az --version
  ```

- **GitHub CLI** (opcional pero recomendado):
  ```bash
  gh --version
  ```

- **Docker** (para build local opcional):
  ```bash
  docker --version
  ```

### Permisos Requeridos

- **Azure**: Contributor en el subscription o resource group
- **GitHub**: Admin del repositorio para crear runners

---

## Paso 1: Crear Recursos de Azure

### 1.1 Definir Variables

```bash
# Configuración General
RESOURCE_GROUP="rg-github-runners-prod"
LOCATION="eastus2"
ENVIRONMENT="env-github-runners"

# Container Registry
CONTAINER_REGISTRY_NAME="githubrunners$(openssl rand -hex 3)"  # Sin guiones!

# Job Configuration
JOB_NAME="dotnet-runner-job"
IMAGE_NAME="github-runner-dotnet:latest"
```

### 1.2 Crear Resource Group

```bash
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION"
```

### 1.3 Crear Container Registry

```bash
az acr create \
  --name "$CONTAINER_REGISTRY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Basic \
  --admin-enabled true
```

### 1.4 Crear Container Apps Environment

```bash
az containerapp env create \
  --name "$ENVIRONMENT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION"
```

---

## Paso 2: Preparar Imagen del Runner

### 2.1 Estructura de Archivos

Crear directorio para los archivos:

```bash
mkdir -p ~/github-runner
cd ~/github-runner
```

### 2.2 Crear `Dockerfile.github`

**ℹ️ NOTA**: Este Dockerfile instala Docker CLI y Azure CLI en la imagen. El .NET SDK **no** se pre-instala — se descarga usando `setup-dotnet` action en el workflow.

```dockerfile
FROM ghcr.io/actions/actions-runner:latest

USER root

# Install basic tools, Docker CLI, and GitHub CLI (no .NET SDK pre-installed)
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    git \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y docker-ce-cli gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Azure CLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Create dotnet directory with correct permissions for setup-dotnet action
RUN mkdir -p /usr/share/dotnet && \
    chown -R runner:runner /usr/share/dotnet

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner

ENTRYPOINT ["/entrypoint.sh"]
```

**Ventajas de este approach:**
- ✅ Imagen sin .NET SDK (~400 MB con Docker CLI + Azure CLI vs ~700 MB con SDK)
- ✅ Flexible: cambiar versión de .NET sin rebuild de imagen
- ✅ Soporta múltiples versiones de .NET en el mismo runner

**Desventajas:**
- ⚠️ Primera ejecución más lenta (~30 segundos para download de SDK)
- ⚠️ Requiere acceso a internet en cada ejecución inicial

### 2.3 Crear `entrypoint.sh`

**⚠️ IMPORTANTE**: Crear con Unix line endings (LF, NO CRLF)

```bash
#!/bin/bash
set -e

echo "Starting GitHub Actions Runner for ${REPO_OWNER}/${REPO_NAME}"

# Get registration token from GitHub API
echo "Obtaining registration token..."
REGISTRATION_TOKEN=$(curl -sX POST \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token" \
  | jq -r .token)

if [ -z "$REGISTRATION_TOKEN" ] || [ "$REGISTRATION_TOKEN" = "null" ]; then
  echo "ERROR: Failed to get registration token. Check your GITHUB_PAT and repo permissions."
  exit 1
fi

echo "Configuring runner..."
./config.sh \
  --url "https://github.com/${REPO_OWNER}/${REPO_NAME}" \
  --token "${REGISTRATION_TOKEN}" \
  --name "${HOSTNAME}" \
  --work "_work" \
  --labels "azure-container-apps,self-hosted,dotnet" \
  --unattended \
  --ephemeral \
  --replace

# Cleanup function
cleanup() {
  echo "Removing runner..."
  ./config.sh remove --token "${REGISTRATION_TOKEN}" || true
}
trap cleanup EXIT

echo "Starting runner..."
./run.sh
```

### 2.4 Build y Push de la Imagen

```bash
# Build local (opcional, para testing)
docker build -t github-runner-dotnet:local -f Dockerfile.github .

# Build directo en ACR (recomendado)
az acr build \
  --registry "$CONTAINER_REGISTRY_NAME" \
  --image "$IMAGE_NAME" \
  --file Dockerfile.github \
  . \
  --no-logs
```

### 2.5 Actualizar Imagen y Job (cuando hay cambios)

Cuando modifiques el `Dockerfile.github`, incrementá el tag y actualizá el job:

**Paso 1: Build nueva imagen en ACR** (~3-4 minutos)

```bash
az acr build \
  --registry testselfhostedrunner \
  --image github-actions-runner:4.0 \
  --file Dockerfile.github \
  . \
  --no-logs
```

**Paso 2: Actualizar el Container Apps Job con la nueva imagen** (~10 segundos)

```bash
az containerapp job update \
  --name github-actions-runner-job \
  --resource-group rg-far-jobs-sample \
  --image testselfhostedrunner.azurecr.io/github-actions-runner:4.0
```

> 💡 Reemplazá `4.0` con el tag correspondiente a cada nueva versión. No uses `:latest` en producción — los tags semánticos permiten rollback.

---

## Paso 3: Configurar GitHub

### 3.1 Crear Personal Access Token (PAT)

1. Ir a: https://github.com/settings/tokens?type=beta
2. Click **"Generate new token"** → **"Fine-grained tokens"**
3. Configurar:
   - **Token name**: `github-runner-pat-<repo-name>`
   - **Expiration**: 90 days (rotar regularmente)
   - **Repository access**: Only select repositories → Seleccionar tu repo
   - **Repository permissions**:
     - `Actions`: Read and write
     - `Administration`: Read and write
     - `Metadata`: Read-only

4. Click **"Generate token"** y copiar el valor

### 3.2 Guardar PAT como Variable

```bash
GITHUB_PAT="github_pat_XXXXXXXXXXXXXXXX"  # Tu PAT
REPO_OWNER="tu-usuario"
REPO_NAME="tu-repositorio"
```

---

## Paso 4: Desplegar Container Apps Job

### 4.1 Crear Job con Configuración Manual

```bash
az containerapp job create \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENVIRONMENT" \
  --trigger-type "Manual" \
  --replica-timeout 1800 \
  --replica-retry-limit 0 \
  --parallelism 1 \
  --image "$CONTAINER_REGISTRY_NAME.azurecr.io/$IMAGE_NAME" \
  --cpu 2 \
  --memory 4Gi \
  --registry-server "$CONTAINER_REGISTRY_NAME.azurecr.io" \
  --secrets \
    "github-pat=$GITHUB_PAT" \
  --env-vars \
    "REPO_OWNER=$REPO_OWNER" \
    "REPO_NAME=$REPO_NAME" \
    "GITHUB_PAT=secretref:github-pat"
```

### 4.2 Verificar Deployment

```bash
# Verificar que el job fue creado
az containerapp job show \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "{name:name, triggerType:properties.configuration.triggerType}" \
  -o table

# Test manual execution
az containerapp job start \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP"

# Ver logs
az containerapp job execution list \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output table
```

---

## Paso 5: Configurar KEDA Autoscaling

### 5.1 Actualizar Job a Event-Driven

```bash
az containerapp job update \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --trigger-type "Event" \
  --replica-timeout 1800 \
  --replica-retry-limit 1 \
  --parallelism 1 \
  --min-executions 0 \
  --max-executions 10 \
  --polling-interval 30 \
  --scale-rule-name "github-runner" \
  --scale-rule-type "github-runner" \
  --scale-rule-metadata \
    "githubAPIURL=https://api.github.com" \
    "owner=$REPO_OWNER" \
    "repos=$REPO_NAME" \
    "targetWorkflowQueueLength=1" \
  --scale-rule-auth "personalAccessToken=github-pat"
```

### 5.2 Verificar KEDA Configuration

```bash
az containerapp job show \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.eventTriggerConfig" \
  -o json
```

**Expected Output:**
```json
{
  "parallelism": 1,
  "replicaCompletionCount": 1,
  "scale": {
    "maxExecutions": 10,
    "minExecutions": 0,
    "pollingInterval": 30,
    "rules": [
      {
        "auth": [
          {
            "secretRef": "github-pat",
            "triggerParameter": "personalAccessToken"
          }
        ],
        "metadata": {
          "githubAPIURL": "https://api.github.com",
          "owner": "tu-usuario",
          "repos": "tu-repositorio",
          "targetWorkflowQueueLength": "1"
        },
        "name": "github-runner",
        "type": "github-runner"
      }
    ]
  }
}
```

---

## Paso 6: Crear Workflow en GitHub

### 6.1 Ajustar Proyecto .NET

**Archivo**: `src/HelloWorldMvc/HelloWorldMvc.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <!-- ✅ Usar .NET 9.0 (o la versión que configures en setup-dotnet) -->
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
</Project>
```

**Nota**: La versión del `TargetFramework` debe coincidir con la versión configurada en el step `setup-dotnet` del workflow (paso 6.2).

### 6.2 Crear Workflow File

**Archivo**: `.github/workflows/ci.yml`

```yaml
name: CI Build

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build:
    runs-on: self-hosted  # ✅ Usa tu runner
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v4
    
    # ✅ SÍ incluir setup-dotnet - descarga el SDK en cada ejecución
    - name: Setup .NET
      uses: actions/setup-dotnet@v4
      with:
        dotnet-version: '9.0.x'  # Especificar versión deseada
    
    - name: Verify .NET Installation
      run: |
        dotnet --version
        dotnet --list-sdks
    
    - name: Restore dependencies
      run: dotnet restore ./src/HelloWorldMvc/HelloWorldMvc.csproj
    
    - name: Build
      run: dotnet build ./src/HelloWorldMvc/HelloWorldMvc.csproj --no-restore --configuration Release
    
    - name: Test (if tests exist)
      run: dotnet test ./src/HelloWorldMvc/HelloWorldMvc.csproj --no-build --verbosity normal
      continue-on-error: true
    
    # ❌ Docker build NOT supported in Azure Container Apps
    # Build Docker images in a separate pipeline with Docker daemon access
    # (e.g., Azure DevOps, GitHub-hosted runners, or ACR Tasks)
```

**Notas importantes:**
- ✅ `setup-dotnet@v4` descarga e instala .NET en cada ejecución (~30s primera vez, ~5s con cache)
- ✅ `dotnet-version: '9.0.x'` usa la última patch version de .NET 9.0
- ✅ Puedes usar múltiples versiones con `dotnet-version: |` (multi-line)
- ❌ **NO incluir `docker build`** - Azure Container Apps no soporta Docker-in-Docker

### 6.3 Commit y Push

```bash
git add .github/workflows/ci.yml
git add src/HelloWorldMvc/HelloWorldMvc.csproj
git commit -m "Add CI workflow with self-hosted runner"
git push
```

---

## Mejores Prácticas

### 🔐 Seguridad

1. **Rotar PATs regularmente** (cada 90 días)
2. **Usar Fine-grained PATs** (no Classic PATs)
3. **Scope mínimo**: Solo permisos necesarios
4. **Ephemeral runners**: Siempre usar `--ephemeral` flag
5. **VNet isolation**: Configurar VNET para acceso a recursos privados

### 📦 Gestión de Imágenes

1. **Versionar imágenes**: Usar tags semánticos (`v1.0.0`, no `:latest`)
2. **Imagen minimalista**: No pre-instalar SDKs, usar setup actions
3. **Cache layers**: Ordenar comandos RUN por frecuencia de cambio
4. **Security scanning**: Usar `az acr security-scan`

### ⚡ Performance

1. **SDK Caching**: `setup-dotnet` cachea SDKs por ~1 hora en el runner
2. **Cache dependencies**: Usar actions/cache para `.nuget/packages`, etc.
   ```yaml
   - uses: actions/cache@v4
     with:
       path: ~/.nuget/packages
       key: ${{ runner.os }}-nuget-${{ hashFiles('**/*.csproj') }}
   ```
3. **Parallel jobs**: Ejecutar múltiples jobs independientes en paralelo
4. **Warm pools**: Configurar `min-executions: 1` si hay workflows frecuentes

### 🔄 Multi-Repository Setup

Para múltiples repos, crear un job por repo:

```bash
# Job para dotnet-aspnet
az containerapp job create --name dotnet-aspnet-runner ...

# Job para nodejs-api
az containerapp job create --name nodejs-api-runner ...
```

O usar **runner groups** en GitHub Enterprise.

---

## Troubleshooting

### ❌ Error: "exec /entrypoint.sh: no such file or directory"

**Causa**: `entrypoint.sh` tiene Windows line endings (CRLF)

**Solución**:
```bash
# Convertir a Unix line endings
dos2unix entrypoint.sh
# O recrear el archivo en Linux/WSL
```

### ❌ Error: "failed to connect to the docker API at unix:///var/run/docker.sock"

**Causa**: Azure Container Apps **NO soporta Docker-in-Docker (DinD)**

**Solución**:
1. Eliminar steps de `docker build` del workflow
2. Buildear imágenes Docker en pipelines separados:
   - Azure DevOps con Docker agents
   - GitHub-hosted runners (tienen Docker)
   - ACR Tasks: `az acr build` desde GitHub Actions
   
```yaml
# ❌ NO funciona en Container Apps
- run: docker build -t myapp .

# ✅ Alternativa: ACR Tasks
- run: |
    az acr build \
      --registry myregistry \
      --image myapp:${{ github.sha }} \
      --file Dockerfile \
      .
```

### ❌ Error: "Failed to get registration token"

**Causa**: PAT inválido, expirado, o sin permisos

**Solución**:
1. Verificar que el PAT no esté expirado
2. Verificar permisos: Actions (Read and write), Administration (Read and write)
3. Regenerar PAT si es necesario

### ❌ Error: "NETSDK1045: .NET SDK does not support targeting .NET X.X"

**Causa**: Mismatch entre versión en `<TargetFramework>` del proyecto y versión en `setup-dotnet`

**Solución**:
1. Verificar versión en `setup-dotnet` del workflow:
   ```yaml
   - name: Setup .NET
     uses: actions/setup-dotnet@v4
     with:
       dotnet-version: '9.0.x'  # ← Esta versión
   ```
2. Verificar versión en `.csproj`:
   ```xml
   <TargetFramework>net9.0</TargetFramework>  <!-- ← Debe coincidir -->
   ```
3. Ambas versiones deben ser compatibles

### ❌ Runners no escalan

**Causa**: KEDA scaler no configurado correctamente

**Solución**:
```bash
# Verificar configuration
az containerapp job show \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.eventTriggerConfig"

# Verificar que triggerType sea "Event"
# Verificar que scale rules existan
```

### 📊 Ver Logs en Tiempo Real

```bash
# Obtener último execution ID
EXECUTION_NAME=$(az containerapp job execution list \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].name" -o tsv)

# Ver logs
az containerapp job logs show \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --execution "$EXECUTION_NAME" \
  --follow
```

---

## GitHub Team/Enterprise: Runner Groups

Ver guía completa: **[ENTERPRISE.md](ENTERPRISE.md)**

Disponible desde el plan **GitHub Team** ("GitHub Business"). Un único Container Apps Job para toda la organización, sin necesidad de un job por repo.

---

## Referencias

- **GitHub Actions Runners**: https://docs.github.com/en/actions/hosting-your-own-runners
- **Azure Container Apps Jobs**: https://learn.microsoft.com/en-us/azure/container-apps/jobs
- **KEDA GitHub Scaler**: https://keda.sh/docs/scalers/github-runner/
- **.NET CLI**: https://learn.microsoft.com/en-us/dotnet/core/tools/

---

## 📄 Licencia

MIT License - Libre para usar y modificar

---

**Última actualización**: Agosto 2026  
**Versiones testeadas**: .NET 9.0, Azure CLI 2.50+, GitHub Actions latest
