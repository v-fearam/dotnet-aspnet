# GitHub Team / Enterprise: Runner Groups (Multi-Repo)

> **Para organizaciones con GitHub Team ("GitHub Business") o GitHub Enterprise.**  
> Con Free necesitás un Container Apps Job por repo. Desde el plan **Team** ya podés usar Runner Groups para cubrir múltiples repos con un único job.

| Plan | Runner Groups | Alcance |
|---|---|---|
| GitHub Free | ❌ | — |
| **GitHub Team** ("Business") | ✅ | A nivel de organización |
| GitHub Enterprise Cloud | ✅ | Org + Enterprise (multi-org) |
| GitHub Enterprise Server | ✅ | Org + Enterprise (multi-org) |

---

## ¿Qué es un Runner Group?

Un runner group es un pool de runners administrado a nivel de **organización** (no repo). Vos decidís qué repos de la org pueden usarlo. Un solo Container Apps Job alimenta el grupo y atiende todos los repos autorizados.

```
GitHub Org
  └── Runner Group: "azure-container-apps"
        ├── repo-frontend  ✅ (acceso autorizado)
        ├── repo-backend   ✅ (acceso autorizado)
        └── repo-infra     ✅ (acceso autorizado)
              ↓
    Un solo Container Apps Job escala para toda la org
```

---

## Diferencias vs. setup repo-level

| | Repo-level (Free/Team) | Enterprise + Runner Groups |
|---|---|---|
| Token API | `/repos/{owner}/{repo}/actions/runners/registration-token` | `/orgs/{org}/actions/runners/registration-token` |
| `--url` en config.sh | `https://github.com/owner/repo` | `https://github.com/ORG_NAME` |
| `--runnergroup` | no aplica | `--runnergroup "nombre-del-grupo"` |
| Jobs de ACA necesarios | 1 por repo | 1 por grupo (cubre N repos) |
| `runs-on` en workflow | `self-hosted` | `group: nombre-del-grupo` |
| KEDA `repos` param | un repo | lista de repos o vacío (toda la org) |

---

## Paso 1: Crear el Runner Group en GitHub

1. Ir a `https://github.com/organizations/{ORG}/settings/actions/runner-groups`
2. Click **"New runner group"**
3. Configurar:
   - **Name**: `azure-container-apps`
   - **Repository access**: seleccioná los repos autorizados (o "All repositories")
4. Guardar — anotá el nombre exacto del grupo, lo usás en `entrypoint.sh`

---

## Paso 2: Crear el PAT con permisos de org

El PAT necesita un scope adicional respecto al setup repo-level:

| Permiso | Repo-level | Org-level (Enterprise) |
|---|---|---|
| `Actions` | Read and write | Read and write |
| `Administration` | Read and write | Read and write |
| `Metadata` | Read-only | Read-only |
| **`Organization self-hosted runners`** | ❌ | ✅ **Read and write** |

**⚠️ Diferencia clave vs. repo-level**: el fine-grained token debe tener como `Resource owner` la **organización**, no tu cuenta personal. Sin esto, el permiso `Organization self-hosted runners` no aparece.

1. Ir a `https://github.com/settings/tokens?type=beta`
2. Click **"Generate new token"** → **"Fine-grained tokens"**
3. En **"Resource owner"** → cambiar de tu usuario a **la organización** (desplegable)
   > Si no aparece la org, un admin de la org debe habilitar primero: `Org Settings → Personal access tokens → Allow fine-grained personal access tokens`
4. **Expiration**: 90 days
5. **Repository access**: All repositories (o seleccioná los específicos)
6. **Organization permissions**:
   - `Self-hosted runners`: Read and write
7. **Repository permissions**:
   - `Actions`: Read and write
   - `Administration`: Read and write
   - `Metadata`: Read-only
8. Click **"Generate token"** y guardar

---

## Paso 3: Adaptar `entrypoint.sh` para org-level

Tres cambios respecto al script repo-level:

```bash
#!/bin/bash
set -e

echo "Starting GitHub Actions Runner for org: ${ORG_NAME}"

# Token de org (no de repo)
REGISTRATION_TOKEN=$(curl -sX POST \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token" \
  | jq -r .token)

if [ -z "$REGISTRATION_TOKEN" ] || [ "$REGISTRATION_TOKEN" = "null" ]; then
  echo "ERROR: Failed to get registration token."
  exit 1
fi

./config.sh \
  --url "https://github.com/${ORG_NAME}" \
  --token "${REGISTRATION_TOKEN}" \
  --name "${HOSTNAME}" \
  --work "_work" \
  --runnergroup "azure-container-apps" \
  --labels "azure-container-apps,self-hosted" \
  --unattended \
  --ephemeral \
  --replace

cleanup() {
  ./config.sh remove --token "${REGISTRATION_TOKEN}" || true
}
trap cleanup EXIT

./run.sh
```

---

## Paso 4: Actualizar variables del Container Apps Job

```bash
az containerapp job update \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --env-vars \
    "ORG_NAME=nombre-de-tu-org" \
    "GITHUB_PAT=secretref:github-pat"
# Eliminar REPO_OWNER y REPO_NAME — ya no aplican
```

---

## Paso 5: Ajustar KEDA para org-level

```bash
az containerapp job update \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --scale-rule-metadata \
    "githubAPIURL=https://api.github.com" \
    "owner=${ORG_NAME}" \
    "repos=repo-frontend,repo-backend,repo-infra" \
    "targetWorkflowQueueLength=1" \
  --scale-rule-auth "personalAccessToken=github-pat"
```

> Si querés que escale ante cualquier repo de la org, omitir `repos` — el scaler soporta queue a nivel de org cuando no se especifica.

---

## Paso 6: `runs-on` en los workflows de cada repo

```yaml
jobs:
  build:
    runs-on:
      group: azure-container-apps   # nombre del runner group
      labels: [ self-hosted ]       # opcional, filtra dentro del grupo
```

---

## Múltiples grupos por stack (ej: .NET y Node.js)

Podés tener tantos grupos como necesites, cada uno con su propia imagen y job:

```
GitHub Org
  ├── Runner Group: "runners-dotnet"
  │     ├── repo-api         (usa .NET)
  │     └── repo-mvc         (usa .NET)
  │
  └── Runner Group: "runners-node"
        ├── repo-frontend    (usa Node.js)
        └── repo-bff         (usa Node.js)
```

En Azure: dos Container Apps Jobs, cada uno apuntando a una imagen distinta.
El `entrypoint.sh` es el mismo — solo cambia `--runnergroup` y el `ORG_NAME`.

```bash
# Job para runners .NET
az containerapp job create \
  --name "runners-dotnet-job" \
  --image "$ACR.azurecr.io/github-runner-dotnet:x.x" \
  --env-vars "ORG_NAME=$ORG" "GITHUB_PAT=secretref:github-pat" \
  # ... resto de parámetros igual

# Job para runners Node
az containerapp job create \
  --name "runners-node-job" \
  --image "$ACR.azurecr.io/github-runner-node:x.x" \
  --env-vars "ORG_NAME=$ORG" "GITHUB_PAT=secretref:github-pat" \
  # ...
```

En el script `entrypoint.sh`, parametrizá `--runnergroup` con una variable de entorno:

```bash
./config.sh \
  --url "https://github.com/${ORG_NAME}" \
  --token "${REGISTRATION_TOKEN}" \
  --runnergroup "${RUNNER_GROUP}" \
  --labels "azure-container-apps,self-hosted" \
  --unattended --ephemeral --replace
```

Y en el workflow de cada repo, seleccionás el grupo correspondiente:

```yaml
# Repo .NET
jobs:
  build:
    runs-on:
      group: runners-dotnet

# Repo Node.js
jobs:
  build:
    runs-on:
      group: runners-node
```

---

## Referencias

- **Runner Groups — GitHub Docs**: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/managing-access-to-self-hosted-runners-using-groups
- **Org-level runner registration API**: https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-an-organization
- **KEDA GitHub Runner Scaler**: https://keda.sh/docs/scalers/github-runner/
- **Container Apps Jobs + KEDA**: https://learn.microsoft.com/en-us/azure/container-apps/tutorial-event-driven-jobs
- **GitHub Enterprise — Self-hosted runners**: https://docs.github.com/en/enterprise-cloud@latest/actions/hosting-your-own-runners/about-self-hosted-runners
