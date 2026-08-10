# GitHub Actions Self-Hosted Runners en Azure Container Apps
## Guía Completa: Desde Cero hasta Producción

Esta guía documenta la implementación completa de GitHub Actions self-hosted runners usando Azure Container Apps con .NET pre-instalado.

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
    ├── .NET SDK 9.0 (pre-installed)
    ├── Docker CLI
    ├── Azure CLI (opcional)
    └── Custom tools
```

**Características:**
- ✅ Autoscaling 0-N basado en queue de workflows
- ✅ Runners efímeros (se destruyen después de cada job)
- ✅ VNet integration para acceso a recursos privados
- ✅ SDKs pre-instalados (sin download en cada run)

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

```dockerfile
FROM ghcr.io/actions/actions-runner:latest

USER root

# Install tools and .NET SDK 9.0 (LTS)
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    git \
    wget \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install .NET SDK 9.0
RUN wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh \
    && chmod +x ./dotnet-install.sh \
    && ./dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
    && rm dotnet-install.sh

# Verify .NET installation
RUN dotnet --version && dotnet --list-sdks

# Optional: Install Azure CLI
# RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner

ENTRYPOINT ["/entrypoint.sh"]
```

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
    <!-- ✅ Usar .NET 9.0 (compatible con SDK pre-instalado) -->
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
</Project>
```

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
    
    # ❌ NO incluir setup-dotnet - .NET ya está pre-instalado!
    
    - name: Verify .NET Installation
      run: |
        dotnet --version
        dotnet --list-sdks
    
    - name: Restore dependencies
      run: dotnet restore ./src/HelloWorldMvc/HelloWorldMvc.csproj
    
    - name: Build
      run: dotnet build ./src/HelloWorldMvc/HelloWorldMvc.csproj --no-restore --configuration Release
    
    - name: Test
      run: dotnet test ./src/HelloWorldMvc/HelloWorldMvc.csproj --no-build --verbosity normal
    
    # Optional: Build Docker image
    - name: Build Docker image
      run: |
        docker build -t helloworldmvc:${{ github.sha }} ./src/HelloWorldMvc
```

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
2. **Multi-stage builds**: Reducir tamaño de imagen
3. **Cache layers**: Ordenar comandos RUN por frecuencia de cambio
4. **Security scanning**: Usar `az acr security-scan`

### ⚡ Performance

1. **Pre-instalar herramientas**: Evitar download en cada run
2. **Cache dependencies**: Usar actions/cache para `node_modules`, `.nuget`, etc.
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

### ❌ Error: "Failed to get registration token"

**Causa**: PAT inválido, expirado, o sin permisos

**Solución**:
1. Verificar que el PAT no esté expirado
2. Verificar permisos: Actions (Read and write), Administration (Read and write)
3. Regenerar PAT si es necesario

### ❌ Error: "NETSDK1045: .NET SDK does not support targeting .NET X.X"

**Causa**: Proyecto usa .NET version no instalada en el runner

**Solución**:
1. Cambiar `<TargetFramework>` en `.csproj` a versión instalada (e.g., `net9.0`)
2. O actualizar Dockerfile para instalar la versión correcta

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
