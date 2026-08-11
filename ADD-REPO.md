# Agregar un Nuevo Repo al Runner Existente

> **Prerequisito**: El environment de Azure Container Apps ya está funcionando (Paso 1 a 5 del README completados).  
> Esto es para **GitHub Free/Team** — un Container Apps Job por repo.

---

## Qué se necesita hacer

| Tarea | Tiempo estimado |
|---|---|
| Crear PAT para el nuevo repo | 2 min |
| Crear nuevo Container Apps Job | 2 min |
| Configurar KEDA en el job | 1 min |
| Agregar `.github/workflows/ci.yml` al repo | 5 min |
| Verificar primera ejecución | 5 min |

---

## Paso 1: Crear PAT para el nuevo repo

1. Ir a `https://github.com/settings/tokens?type=beta`
2. Click **"Generate new token"** → **"Fine-grained tokens"**
3. Configurar:
   - **Token name**: `github-runner-pat-NOMBRE-REPO`
   - **Expiration**: 90 days
   - **Repository access**: Only select repositories → seleccionar **solo el nuevo repo**
   - **Permissions**:
     - `Actions`: Read and write
     - `Administration`: Read and write
     - `Metadata`: Read-only
4. Guardar el token

---

## Paso 2: Definir variables

```bash
# Usar el mismo resource group y environment existentes
RESOURCE_GROUP="rg-github-runners-prod"
ENVIRONMENT="env-github-runners"
CONTAINER_REGISTRY_NAME="<tu-registry-existente>"

# Nuevo repo
REPO_OWNER="tu-org"
REPO_NAME="nombre-del-nuevo-repo"
JOB_NAME="${REPO_NAME}-runner-job"           # nombre único por repo
GITHUB_PAT="github_pat_XXXXXXXXXXXXXXXX"    # PAT del paso 1
IMAGE_NAME="github-actions-runner:4.0"      # misma imagen existente
```

---

## Paso 3: Crear el Container Apps Job

```bash
az containerapp job create \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENVIRONMENT" \
  --trigger-type "Event" \
  --replica-timeout 1800 \
  --replica-retry-limit 1 \
  --parallelism 1 \
  --min-executions 0 \
  --max-executions 10 \
  --polling-interval 30 \
  --image "$CONTAINER_REGISTRY_NAME.azurecr.io/$IMAGE_NAME" \
  --cpu 2 \
  --memory 4Gi \
  --registry-server "$CONTAINER_REGISTRY_NAME.azurecr.io" \
  --secrets \
    "github-pat=$GITHUB_PAT" \
  --env-vars \
    "REPO_OWNER=$REPO_OWNER" \
    "REPO_NAME=$REPO_NAME" \
    "GITHUB_PAT=secretref:github-pat" \
  --scale-rule-name "github-runner" \
  --scale-rule-type "github-runner" \
  --scale-rule-metadata \
    "githubAPIURL=https://api.github.com" \
    "owner=$REPO_OWNER" \
    "repos=$REPO_NAME" \
    "targetWorkflowQueueLength=1" \
  --scale-rule-auth "personalAccessToken=github-pat"
```

> ℹ️ Este comando crea el job ya con trigger Event y KEDA configurado en un solo paso.

---

## Paso 4: Verificar que el job fue creado correctamente

```bash
az containerapp job show \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "{name:name, trigger:properties.configuration.triggerType, image:properties.template.containers[0].image}" \
  -o table
```

Resultado esperado:

```
Name                        Trigger    Image
--------------------------  ---------  ------------------------------------------------
nombre-del-nuevo-repo-job   Event      turegistry.azurecr.io/github-actions-runner:4.0
```

---

## Paso 5: Agregar el workflow al nuevo repo

Crear el archivo `.github/workflows/ci.yml` en el nuevo repo:

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
    runs-on: self-hosted

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Setup .NET
      uses: actions/setup-dotnet@v4
      with:
        dotnet-version: '9.0.x'

    - name: Restore
      run: dotnet restore

    - name: Build
      run: dotnet build --no-restore --configuration Release

    - name: Test
      run: dotnet test --no-build --verbosity normal
      continue-on-error: true
```

```bash
git add .github/workflows/ci.yml
git commit -m "Add CI workflow with self-hosted runner"
git push
```

---

## Paso 6: Verificar primera ejecución

Después del push, el KEDA scaler debería detectar el workflow en queue y levantar una réplica:

```bash
# Ver ejecuciones del job
az containerapp job execution list \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output table

# Ver logs de la última ejecución
EXECUTION_NAME=$(az containerapp job execution list \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].name" -o tsv)

az containerapp job logs show \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --execution "$EXECUTION_NAME" \
  --follow
```

En los logs deberías ver:
```
Starting GitHub Actions Runner for tu-org/nombre-del-nuevo-repo
Obtaining registration token...
Configuring runner...
Starting runner...
```

---

## Checklist rápido

- [ ] PAT creado con scope solo al nuevo repo
- [ ] `JOB_NAME` único (no pisar jobs existentes)
- [ ] Mismo `ENVIRONMENT` y `RESOURCE_GROUP` del setup original
- [ ] Misma imagen del registry existente
- [ ] `.github/workflows/ci.yml` commiteado al nuevo repo
- [ ] Primera ejecución visible en `az containerapp job execution list`
