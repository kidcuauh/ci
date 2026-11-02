# check-infra

Verifica el `infra/` de un repo que consume el chart `app`, sin cluster ni secretos. Es el mismo script en local y en CI: `scripts/check-infra.sh`. El workflow reutilizable `check-infra.yml` lo instala y lo corre con `contents: read` y sin secretos.

La verificación no sustituye las barreras de la plataforma (permisos del ServiceAccount del tenant y políticas de admisión): atrapa el error antes de que llegue al cluster y da un mensaje que dice qué cambiar.

## Uso en CI

```yaml
name: check-infra
on:
  pull_request:
  push:
    branches: [main]
permissions: {}
jobs:
  check-infra:
    permissions:
      contents: read
    uses: kidcuauh/ci/.github/workflows/check-infra.yml@main   # en producción fija un tag o el SHA completo del commit
```

`@main` solo sirve para probar: un repo de producción debe fijar un tag o un commit SHA completo.

| Input | Tipo | Por defecto | Notas |
|---|---|---|---|
| `path` | string | `.` | Directorio del repo que contiene `infra/`. Relativo, sin `..` |
| `kubernetes-version` | string | `1.36.5` | `X.Y.Z`; versión de los esquemas de Kubernetes |

## Uso en local

```bash
bash scripts/install-tools.sh helm flux kubeconform gitleaks yq   # una vez; TOOLS_BIN=<dir> en local
bash scripts/check-infra.sh [--chart-dir DIR] [--kubernetes-version X.Y.Z] [--schemas DIR] <raíz-del-repo>
```

- `--chart-dir DIR` usa ese chart local en vez de bajarlo por digest. Sirve para probar un chart antes de publicarlo; el nombre en `Chart.yaml` debe coincidir con el del `OCIRepository`.
- `--schemas DIR` cambia los esquemas de los CRD (por defecto `schemas/` de este repo).
- Salida: `ERROR <archivo>: <qué cambiar>` por cada problema, todos juntos. Código 0 si todo pasa, 1 si hubo errores, 2 si falta una herramienta, los argumentos son inválidos o se pide `--help`.
- Sin `--chart-dir`, baja el chart de forma anónima (`helm pull oci://ghcr.io/kidcuauh/charts/<chart>@<digest>`), así que el paquete debe ser público y el digest, uno publicado.

## Qué comprueba

1. **Forma.** Existe `infra/overlays/prod/kustomization.yaml`; cada entrada de `infra/overlays/` (también las que empiezan con punto) es una carpeta con nombre en minúsculas, dígitos y guiones (DNS-1123) y su `kustomization.yaml`.
2. **Estático, sin ejecutar nada.** Sobre todo `infra/`: ningún documento `kind: Secret`; ningún enlace simbólico que salga de `infra/`; en cada kustomization, `resources`, `components`, `bases`, `crds`, `patches`, parches y archivos de generadores solo con rutas locales que no salen de `infra/` (se rechazan URL, `git@`, `github.com/`, `?ref=` y rutas absolutas); sin anclas, alias ni `<<` en las kustomization. Los campos de kustomization son una lista cerrada y sensible a mayúsculas (`resources`, `components`, `patches`, `replacements`, `configMapGenerator`, `namespace`, `labels`, `images`, `replicas`...): `helmCharts`, `helmGlobals`, `helmChartInflationGenerator`, `generators`, `transformers`, `validators`, `openapi`, `secretGenerator`, `configurations`, `vars`, o una escritura distinta como `Resources`, son un error. Si algo de esto falla, no se construye ningún overlay.
3. **Cada overlay se construye** con `flux build kustomization --dry-run` y el resultado debe cumplir: sin `kind: Secret`, sin `metadata.namespace` (lo pone la plataforma), sin kinds prohibidos (RBAC, NetworkPolicy, ResourceQuota, LimitRange, Endpoints, DaemonSet, objetos de fuentes de Flux y de autenticación de Infisical, Traefik, Gateway API, Prometheus Operator, DNSEndpoint y los recursos de alcance cluster conocidos) y validar con `kubeconform -strict` contra los esquemas de Kubernetes y los de `schemas/`. Un kind sin esquema es un error: no se ignoran los desconocidos.
4. **OCIRepository y HelmRelease.**
   - `OCIRepository`: `spec.url` es `oci://ghcr.io/kidcuauh/charts/<chart>`; `spec.ref` trae solo `digest` (`sha256:` y 64 hex); `verify.provider: cosign` con una identidad exacta (contrato de abajo); sin `insecure`, `serviceAccountName`, `secretRef`, `certSecretRef` o `proxySecretRef`; `provider` ausente o `generic`.
   - `HelmRelease`: solo `chartRef` hacia un `OCIRepository` del mismo overlay (sin namespace); `serviceAccountName: tenant-reconciler`; los campos de `spec` son una lista cerrada (`interval`, `serviceAccountName`, `chartRef`, `install`, `upgrade`, `values`, `releaseName`, `timeout`, `test`, `rollback`, `uninstall`, `driftDetection`, `maxHistory`); `chart`, `kubeConfig`, `targetNamespace`, `storageNamespace`, `valuesFrom`, `postRenderers`, `dependsOn`, `install.createNamespace` y `crds` son un error. Cada overlay declara al menos un `HelmRelease`.
5. **`helm template`** de cada `HelmRelease` con sus `spec.values` (nombre del release: `spec.releaseName` o el nombre del objeto; debe ser DNS-1123 de hasta 53 caracteres). El resultado pasa las mismas reglas del punto 3, así que los values que el schema del chart rechaza o que producen un kind prohibido fallan aquí.
6. **gitleaks solo sobre `infra/`**, nunca sobre el resto del repo ni su historial: un literal de credencial en el código fuera de `infra/` no hace fallar la verificación. Se usa la configuración por defecto de gitleaks sobre una copia de `infra/` con nombres neutros: ni una `.gitleaks.toml`, un `.gitleaksignore` o un `gitleaks:allow` dentro de `infra/`, ni la lista de rutas que gitleaks ignora por defecto (`node_modules`, `vendor`, `*.svg`...) la apagan. Un archivo binario o comprimido en `infra/` es un error, porque gitleaks no mira dentro.

## Contrato de firma

El chart se publica con firma keyless desde `release-chart.yml`; el `OCIRepository` la exige con estos valores exactos:

```yaml
verify:
  provider: cosign
  matchOIDCIdentity:
    - issuer: ^https://token\.actions\.githubusercontent\.com$
      subject: ^https://github\.com/kidcuauh/ci/\.github/workflows/release-chart\.yml@refs/tags/chart-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$
```

Cambiar el nombre del workflow, el patrón de tag `chart-v*` o el prefijo `ghcr.io/kidcuauh/charts/` rompe a todos los consumidores.

## Límites

- La lista de kinds de alcance cluster es de mejor esfuerzo: un kind cluster desconocido sin esquema falla en kubeconform, y uno con esquema lo frena la plataforma al aplicar.
- No verifica que el digest exista ni que la firma sea válida: eso lo hacen `helm pull` (si no se usa `--chart-dir`) y el controlador de Flux en el cluster.
- No ejecuta nada del repo que revisa; sí lee sus archivos con `yq`, `flux build` y `helm template`.

## Esquemas (`schemas/`)

JSON Schema generados de los CRD oficiales fijados por URL y sha256: Flux (`OCIRepository`, `GitRepository`, `HelmRelease`, `Kustomization`), operador de Infisical (`InfisicalStaticSecret`), CloudNativePG (`Cluster`, `Backup`, `ScheduledBackup`, `Pooler`) y Percona Operator for MongoDB (`PerconaServerMongoDB`, `PerconaServerMongoDBBackup`, `PerconaServerMongoDBRestore`). Sin `description` y con `additionalProperties: false` donde el CRD define `properties`. Para actualizarlos:

1. En `scripts/update-schemas.sh`, cambia la URL y el sha256 (`shasum -a 256 <archivo>`) de la fuente.
2. `bash scripts/update-schemas.sh` (requiere `curl`, `yq` y `python3`) regenera la carpeta entera.
3. Revisa el diff de `schemas/` y corre `bash scripts/test-check-infra.sh`.

## Pruebas

`bash scripts/test-check-infra.sh` corre los ejemplos de `examples/` y cada caso negativo de `tests/check-infra/cases/`, comprobando el código de salida y el texto del error. Un caso es una carpeta con `expect` (texto esperado) y, según haga falta, `expect2` (un segundo texto), `yq` (mutaciones sobre una copia de `examples/solo-prod`), `files/` y `remove`. Los casos que necesitan un literal de credencial lo generan en el momento: ningún archivo del repo lo contiene.
