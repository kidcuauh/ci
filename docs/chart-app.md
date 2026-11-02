# Chart app

Chart Helm para una aplicación web con sus workers y cron jobs. Se publica como artefacto OCI firmado en `oci://ghcr.io/kidcuauh/charts/app` y se consume desde un `HelmRelease` de Flux, **por digest**. Los values de cada app viven en el repo de quien la usa; el chart no trae hostnames, orgs ni IDs por defecto.

- Un release = una imagen. Una app con varias imágenes usa varios releases.
- El chart no es una barrera de seguridad: da uniformidad (Pod Security restricted, secretos solo por referencia, probes y recursos obligatorios). Las barreras reales son las políticas de admisión y los permisos de la plataforma.
- Todo el contrato de abajo se prueba con `bash scripts/test-chart.sh` (sin cluster; necesita `helm` y `yq`).

## Qué renderiza

| Objeto | Cuándo |
|---|---|
| `Deployment` `<release>` | `web.enabled` (por defecto sí) |
| `Service` `<release>` (ClusterIP, puerto `http` con nombre y `targetPort` por nombre) | `web.enabled` |
| `Ingress` `<release>` (`ingressClassName: traefik`, `pathType: Prefix`) | `web.ingress.enabled` |
| `Deployment` `<release>-<worker>` | un Deployment por elemento de `workers` |
| `CronJob` `<release>-<cron>` (`concurrencyPolicy: Forbid`) | un CronJob por elemento de `cronJobs` |
| `Job` `<release>-migrations` (hook de Helm) | `migrations.enabled` |
| `PodDisruptionBudget` (`maxUnavailable: 1`) | web o worker con `replicas >= 2` |
| `ServiceAccount` `<release>` (sin automount del token) | `serviceAccount.create` |
| `InfisicalStaticSecret` `<release>` (`secrets.infisical.com/v1beta1`) | `secrets.infisical.enabled` |

Nunca renderiza `Secret`, `ConfigMap`, `PersistentVolumeClaim`, `NetworkPolicy`, `Role`, `RoleBinding`, `ClusterRole*` ni `HTTPRoute`. Los permisos que necesita quien aplica el chart son solo los de los objetos de la tabla.

## Cómo se usa

Cada repo lleva una carpeta `infra/` con una base compartida por todos los ambientes y una carpeta por ambiente. Las bases y overlays no llevan `metadata.namespace`: el namespace lo pone quien los aplica. Con varias apps en un namespace, **todos los nombres llevan el nombre de la app** (`<app>-chart`, `<app>`): si dos fuentes aplican el mismo nombre, el segundo se rechaza.

Hay dos formas, copiables tal cual (reemplaza `mi-app`, `mi-org` y los hosts):

- [Solo `prod`](#solo-prod): un repo sin ambiente de desarrollo.
- [Dev y `prod`](#dev-y-prod): cada build de `main` llega primero a `dev`.

El patch de cada ambiente contiene `spec.values.image.tag` y `spec.values.image.digest`, y las claves deben existir: un proceso de despliegue puede reescribirlas con `yq` en cada release de la imagen. El `digest` de relleno (`sha256:000…0`) se sustituye por el digest real de la imagen.

## Solo prod

Copia `examples/solo-prod/infra/` a la raíz de tu repo. Un solo ambiente: `prod`.

`infra/base/mi-app/helmrelease.yaml`

```yaml
# Values comunes a todos los ambientes. Lo que cambia por ambiente (imagen, host,
# priorityClassName, réplicas) va en infra/overlays/<env>/mi-app.patch.yaml.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: mi-app
spec:
  interval: 10m
  serviceAccountName: tenant-reconciler
  chartRef:
    kind: OCIRepository
    name: mi-app-chart
  # Sin rollback automático: si un upgrade (o su Job de migraciones) falla, el release
  # queda fallido y se decide a mano.
  install:
    remediation:
      retries: 0
  upgrade:
    remediation:
      retries: 0
      remediateLastFailure: false
  values:
    image:
      repository: ghcr.io/mi-org/mi-app
    imagePullSecrets:
      - ghcr-mi-org
    env:
      - name: LOG_LEVEL
        value: info
    web:
      port: 8080
      probes:
        readiness:
          httpGet:
            path: /healthz
        liveness:
          httpGet:
            path: /healthz
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
      ingress:
        enabled: true
```

`infra/base/mi-app/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ocirepository.yaml
  - helmrelease.yaml
```

`infra/base/mi-app/ocirepository.yaml`

```yaml
# Chart "app" por digest y con firma verificada. Sin metadata.namespace: lo pone la plataforma.
# El nombre lleva el de la app: con varias fuentes en un namespace no puede repetirse.
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: mi-app-chart
spec:
  interval: 10m
  url: oci://ghcr.io/kidcuauh/charts/app
  ref:
    # Digest de la versión del chart (lo da la release chart-vX.Y.Z). Subirlo es un PR manual.
    digest: sha256:05e1ac85102e64c882c152f424f7d11be011187d9973fcaa7dd25ed56e6b35bf
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/kidcuauh/ci/\.github/workflows/release-chart\.yml@refs/tags/chart-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$
```

`infra/overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/mi-app
patches:
  - path: mi-app.patch.yaml
```

`infra/overlays/prod/mi-app.patch.yaml`

```yaml
# image.tag y image.digest los reescribe tu proceso de despliegue en cada release; las claves deben existir.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: mi-app
spec:
  values:
    image:
      tag: "1.0.0"
      digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
    priorityClassName: tenant-prod
    web:
      replicas: 2
      ingress:
        hosts:
          - host: mi-app.example.com
```

## Dev y prod

Copia `examples/minimal/infra/` a la raíz de tu repo. `infra/overlays/dev/` es lo que activa `dev`: cada build de `main` llega ahí con un tag `sha-<12>`, y `prod` recibe las versiones `X.Y.Z`. La base es la misma que la de solo `prod`.

`infra/base/mi-app/helmrelease.yaml`

```yaml
# Values comunes a todos los ambientes. Lo que cambia por ambiente (imagen, host,
# priorityClassName, réplicas) va en infra/overlays/<env>/mi-app.patch.yaml.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: mi-app
spec:
  interval: 10m
  serviceAccountName: tenant-reconciler
  chartRef:
    kind: OCIRepository
    name: mi-app-chart
  # Sin rollback automático: si un upgrade (o su Job de migraciones) falla, el release
  # queda fallido y se decide a mano.
  install:
    remediation:
      retries: 0
  upgrade:
    remediation:
      retries: 0
      remediateLastFailure: false
  values:
    image:
      repository: ghcr.io/mi-org/mi-app
    imagePullSecrets:
      - ghcr-mi-org
    env:
      - name: LOG_LEVEL
        value: info
    web:
      port: 8080
      probes:
        readiness:
          httpGet:
            path: /healthz
        liveness:
          httpGet:
            path: /healthz
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
      ingress:
        enabled: true
```

`infra/base/mi-app/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ocirepository.yaml
  - helmrelease.yaml
```

`infra/base/mi-app/ocirepository.yaml`

```yaml
# Chart "app" por digest y con firma verificada. Sin metadata.namespace: lo pone la plataforma.
# El nombre lleva el de la app: con varias fuentes en un namespace no puede repetirse.
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: mi-app-chart
spec:
  interval: 10m
  url: oci://ghcr.io/kidcuauh/charts/app
  ref:
    # Digest de la versión del chart (lo da la release chart-vX.Y.Z). Subirlo es un PR manual.
    digest: sha256:05e1ac85102e64c882c152f424f7d11be011187d9973fcaa7dd25ed56e6b35bf
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/kidcuauh/ci/\.github/workflows/release-chart\.yml@refs/tags/chart-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$
```

`infra/overlays/dev/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/mi-app
patches:
  - path: mi-app.patch.yaml
```

`infra/overlays/dev/mi-app.patch.yaml`

```yaml
# Esta carpeta es la que activa dev: cada build de main llega aquí (sha-<12>).
# image.tag y image.digest los reescribe tu proceso de despliegue; las claves deben existir.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: mi-app
spec:
  values:
    image:
      tag: "sha-0123456789ab"
      digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
    priorityClassName: tenant-dev
    web:
      ingress:
        hosts:
          - host: mi-app-dev.example.com
```

`infra/overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/mi-app
patches:
  - path: mi-app.patch.yaml
```

`infra/overlays/prod/mi-app.patch.yaml`

```yaml
# image.tag y image.digest los reescribe tu proceso de despliegue en cada release; las claves deben existir.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: mi-app
spec:
  values:
    image:
      tag: "1.0.0"
      digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
    priorityClassName: tenant-prod
    web:
      replicas: 2
      ingress:
        hosts:
          - host: mi-app.example.com
```

## Values

El schema (`values.schema.json`) tiene `additionalProperties: false` en todos los objetos: un campo desconocido se rechaza. Los obligatorios no tienen un default utilizable, así que un values que los omite falla con el nombre de la propiedad.

| Value | Default | Obligatorio | Notas |
|---|---|---|---|
| `image.repository` | `""` | sí | Referencia sin tag ni digest, en minúsculas (`ghcr.io/mi-org/mi-app`) |
| `image.tag` | `""` | sí | Cadena: `sha-<12 hex>` o `X.Y.Z` |
| `image.digest` | `""` | no | Vacío o `sha256:<64 hex>`. Con digest la imagen es `repo:tag@digest` |
| `image.pullPolicy` | `IfNotPresent` | no | `IfNotPresent` o `Always` |
| `imagePullSecrets` | `[]` | no | Nombres `ghcr-<org>` de Secrets que ya existen. Van en el pod, no en la ServiceAccount |
| `priorityClassName` | `""` | sí | `tenant-prod` o `tenant-dev` |
| `serviceAccount.create` | `true` | no | Crea la ServiceAccount (nombre del release si `name` está vacío) |
| `serviceAccount.name` | `""` | con `create: false` | Con `create: false` es el nombre de una ServiceAccount existente (por ejemplo `alloy`) |
| `securityContext.runAsUser` / `runAsGroup` / `fsGroup` | `10001` | no | Enteros >= 1. `runAsNonRoot` siempre es `true` |
| `writablePaths` | `[/tmp]` | no | Cada ruta absoluta se monta como `emptyDir`; el resto del filesystem es de solo lectura |
| `emptyDirSizeLimit` | `256Mi` | no | Límite de cada `emptyDir` |
| `terminationGracePeriodSeconds` | `30` | no | 1 a 3600, para web y workers |
| `placement.zone` | `any` | no | `any` o el valor de una zona (etiqueta DNS, p. ej. `zona-a`); con una zona, `nodeAffinity` requerida por `topology.kubernetes.io/zone` |
| `placement.whenUnsatisfiable` | `ScheduleAnyway` | no | `DoNotSchedule` o `ScheduleAnyway` para el reparto por nodo |
| `env` | `[]` | no | Común a todos los contenedores. Ver [Variables de entorno](#variables-de-entorno) |
| `secrets.infisical.enabled` | `false` | no | Crea la `InfisicalStaticSecret` y el Secret `<release>-secrets`. Referencia un `infisical-auth` que ya existe en el namespace del release (el chart no lo crea) y no debe haber otro Secret con ese nombre. Lo que un tenant puede leer lo acota solo el alcance de esa identidad, no el chart |
| `secrets.infisical.refreshInterval` | `5m` | no | Mínimo 5 minutos (`5m`, `1h`, `1d`) |
| `secrets.infisical.sources` | `[]` | con `enabled` | Una o más `{projectSlug, environmentSlug, secretPath, recursive}`; `secretPath` por defecto `/`, `recursive` por defecto `false` |
| `files.configMaps` | `[]` | no | `[{name, mountPath}]`: monta un ConfigMap existente como directorio de solo lectura |
| `files.secretKeys` | `[]` | no | `[{secret, key, mountPath}]`: monta una llave como archivo (subPath, solo lectura). `secret` vacío = `<release>-secrets` (exige Infisical); si no, un Secret de la lista permitida |
| `persistence.enabled` | `false` | no | Monta un PVC existente solo en el web |
| `persistence.existingClaim` | `""` | con `enabled` | Nombre del PVC. El chart no crea PVC |
| `persistence.mountPath` / `subPath` | `/data` / `""` | no | |
| `web.enabled` | `true` | no | |
| `web.replicas` | `1` | no | 0 a 20 |
| `web.strategy` | `RollingUpdate` | no | `RollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`) o `Recreate` (exige `replicas <= 1`) |
| `web.command` / `web.args` | `[]` | no | |
| `web.port` | `8080` | no | `containerPort` con nombre `http` |
| `web.extraPorts` | `[]` | no | `[{name, port, protocol}]`; contenedor y Service, `targetPort` por nombre; el nombre no puede ser `http` |
| `web.service.port` | `80` | no | Puerto del Service para `http` |
| `web.probes.readiness` / `liveness` | `{}` | sí, con `web.enabled` | Exactamente uno de `httpGet` (`path`; `port` por defecto `http`) o `tcpSocket` (`port`), más `initialDelaySeconds`, `periodSeconds`, `timeoutSeconds`, `failureThreshold`; `successThreshold` solo en readiness. Sin `exec` |
| `web.probes.startup` | `{}` | no | Misma forma; vacío = sin `startupProbe` |
| `web.resources` | `{}` | sí, con `web.enabled` | `requests.cpu`, `requests.memory` y `limits.memory` obligatorios; `limits.cpu` opcional |
| `web.ingress.enabled` | `false` | no | Un release puede no tener Ingress |
| `web.ingress.hosts` | `[]` | con `enabled` | `[{host, path}]`: host en minúsculas y sin comodines; `path` por defecto `/`, siempre `pathType: Prefix` |
| `workers` | `[]` | no | `[{name, command, args, replicas, strategy, resources, probes, env}]`; `name`, `command` y `resources` obligatorios; un Deployment `<release>-<name>` |
| `cronJobs` | `[]` | no | `[{name, schedule, timeZone, command, args, resources, env, ...}]`; ver abajo |
| `migrations.enabled` | `false` | no | Job de migraciones como hook |
| `migrations.command` / `args` | `[]` | `command` con `enabled` | |
| `migrations.resources` | `{}` | con `enabled` | Misma forma que `web.resources` |
| `migrations.activeDeadlineSeconds` | `1800` | no | Plazo del Job |
| `migrations.env` | `[]` | no | Se suma a `env` |

Un `cronJobs[]` admite `activeDeadlineSeconds` (3600), `ttlSecondsAfterFinished` (86400), `backoffLimit` (0), `startingDeadlineSeconds` (300), `successfulJobsHistoryLimit` (1), `failedJobsHistoryLimit` (1), `suspend` (`false`) y `timeZone` (`Etc/UTC`); entre paréntesis, el default. `schedule` es de 5 campos o `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`.

### Variables de entorno

`env` solo admite dos formas:

- `{name, value}`: un literal no secreto. Se rechaza un `name` de credencial separado por guiones bajos (`DB_PASS`, `API_TOKEN`, `SSH_KEY`, `*_SECRET`, `DSN`, `CONNECTION_STRING`...); nombres pegados como `DBPASSWORD` no se detectan y un `value` con forma de credencial (URL con `usuario:clave@`, llaves privadas PEM, tokens de nube o de plataformas de código, JWT).
- `{name, valueFrom: {secretKeyRef: {name, key}}}`: una referencia a un Secret que ya existe. Solo acepta nombres con la forma de los Secrets que crean las bases: `<cluster>-app` (bases PostgreSQL) y `<cluster>-custom-user-secret` (bases MongoDB). Se rechazan los demás nombres, los reservados (`deploy-key-*`, `ghcr-*`, `infisical-*`, `sh.helm.*`) y cualquier valor literal junto a la referencia. El chart solo mira el sufijo: cualquier Secret del namespace con ese sufijo pasa, y la barrera real es el namespace del tenant. La referencia está exenta de la denylist de nombres, así que `DB_PASS` desde un `secretKeyRef` es válido.

Los secretos de la aplicación se declaran en `secrets.infisical.sources`: el chart pide el Secret `<release>-secrets` y lo inyecta con `envFrom` en todos los contenedores. Los Deployments llevan `secrets.infisical.com/auto-reload: "true"`. El chart no acepta valores de secretos ni tiene plantilla de `Secret`.

### Reglas que valida la plantilla

Lo que un schema no puede ver, la plantilla lo rechaza con un mensaje que dice qué cambiar:

- El nombre del release (`metadata.name` del `HelmRelease`): minúsculas, dígitos y guiones, empieza con letra, hasta 40 caracteres, y no es `tenant-reconciler`, `infisical-sync`, `alloy`, `kustomize-controller`, `helm-controller`, `default` ni termina en `-ops`.
- La ServiceAccount efectiva: mismos nombres reservados; con `create: false` el `name` es obligatorio y se rechazan los mismos nombres reservados, salvo `alloy`, que se permite.
- Nombres derivados: `<release>-<cron>` hasta 52 caracteres (el schema limita el release a 40, `workers[].name` y `cronJobs[].name` a 20 y `web.extraPorts[].name` a 15); los nombres de workers y de cronJobs son únicos. Un release no debe llamarse como `<otro-release>-<worker>` ni `<otro-release>-<cron>` en el mismo namespace: los objetos chocarían.
- Puertos de las probes: en el web, un puerto por nombre debe ser `http` o un `web.extraPorts`; en un worker, solo números (no declara puertos con nombre).
- `requests` y `limits` (y `emptyDirSizeLimit`) deben ser cantidades mayores que cero; el chart no comprueba que `requests` no supere a `limits`.
- Con `persistence.enabled`, usa `web.strategy: Recreate`: un volumen RWO no se adjunta a dos nodos y el pod extra del `RollingUpdate` puede quedar atascado.
- `files.secretKeys[].secret` vacío sin Infisical habilitado.
- Rutas de montaje (`writablePaths`, `files`, `persistence`) repetidas, y puertos extra repetidos o iguales a `web.port`.
- `web.ingress.enabled` o `persistence.enabled` con `web.enabled: false`.
- Un release que no renderiza nada.

## Job de migraciones

`migrations.enabled: true` renderiza un Job con los hooks de Helm `post-install` y `pre-upgrade` (`hook-delete-policy: before-hook-creation`), `backoffLimit: 0`, `restartPolicy: Never` y `activeDeadlineSeconds`.

- **Cuándo corre:** en la primera instalación, después de crear los objetos (la ServiceAccount y el Secret de Infisical aún no existen en la fase `pre-install`); en cada actualización, **antes** de los pods nuevos. Un bump de imagen lo ejecuta, también en un repo sin ambiente de desarrollo.
- **Sin rollback:** si el Job falla, el release queda fallido y no se revierte solo (el `HelmRelease` de los ejemplos tiene `retries: 0` y `remediateLastFailure: false`). Se decide a mano: corregir y volver a aplicar, o volver al pin anterior.
- **Reintentos:** ninguno dentro del Job. Si falla a medias, la migración debe ser idempotente.
- **Primera instalación y espera de Helm:** los hooks `post-install` corren después de que Helm espera a que los objetos estén listos. Si la readiness del web depende del esquema migrado, el release no llega a ese punto y el Job no arranca: en la primera instalación, la readiness no debe depender de las migraciones, o la `HelmRelease` debe usar `install.disableWait: true`.
- **Mismo upgrade:** los hooks `pre-upgrade` corren antes de aplicar los manifiestos nuevos; no actives `secrets.infisical.enabled` ni agregues `files.configMaps` en el mismo upgrade que una migración, porque el Job los referenciaría antes de que existan.
- **Primera instalación con secretos:** el Secret `<release>-secrets` lo crea el controlador de Infisical de forma asíncrona; si el Job arranca antes, su pod espera hasta que aparezca y `activeDeadlineSeconds` lo acota.
- Usa la misma imagen, el mismo `env` (más `migrations.env`), los mismos archivos montados y el mismo pod restringido que el web; no monta el PVC.

## Subir el pin del chart

El pin es el `ref.digest` del `OCIRepository` en `infra/base/<app>/ocirepository.yaml`. Cada versión publicada trae su digest en la release `chart-vX.Y.Z` de `kidcuauh/ci`. Subirlo es un cambio manual por repo, con la firma verificada por el propio `OCIRepository`.

- **Con ambiente de desarrollo:** el pin vive en la base compartida, así que cambiarlo en `infra/base/` llegaría a todos los ambientes a la vez. Para probarlo primero en `dev`, agrega a `infra/overlays/dev/kustomization.yaml` un patch que cambie solo `spec.ref.digest`, confirma que el release de `dev` queda sano y entonces cambia `infra/base/` y quita el patch:

  ```yaml
  patches:
    - path: mi-app.patch.yaml
    - target:
        kind: OCIRepository
        name: mi-app-chart
      patch: |-
        - op: replace
          path: /spec/ref/digest
          value: sha256:<digest nuevo>
  ```
- **Sin ambiente de desarrollo (solo `prod`):** el pin llega directo a `prod`, porque los manifiestos se aplican desde `main`. Revisa el [CHANGELOG](../charts/app/CHANGELOG.md) y ejecuta `helm template` con tus values contra el chart nuevo antes de fusionar.

Las dos formas se comprueban antes de fusionar con `helm template <app> <chart> -f values.yaml`, donde `values.yaml` es la mezcla de la `HelmRelease` base y el patch del ambiente.

## Versionado

- SemVer. Es cambio mayor quitar o renombrar values, endurecer el schema de modo que un values válido deje de serlo, o cambiar la forma del release. El `spec.selector` de los Deployments nunca cambia, ni en una versión mayor (lo fija un test contra un golden en `tests/chart/golden/`, que solo se edita para agregar casos nuevos).
- Un tag `chart-vX.Y.Z` sobre un commit de `main` publica la versión `X.Y.Z` (los tags `chart-vX.Y.Z-rc.N` publican prereleases), la firma y crea una release inmutable. Los tags de GHCR son mutables: se consume **por digest**, y el workflow nunca sobrescribe una versión.
- Sin backports. Cada cambio mayor trae su guía de migración en el [CHANGELOG](../charts/app/CHANGELOG.md).
- Los workflows reutilizables (`@main`) y el chart versionan por separado.

## Contrato inmutable

Estos nombres los usan los repos que consumen el chart y las políticas que verifican su firma; cambiarlos rompe a todos:

| Qué | Valor |
|---|---|
| Referencia del chart | `oci://ghcr.io/kidcuauh/charts/app` (ruta en el repo: `charts/app`, nombre `app`) |
| Workflow de publicación | `.github/workflows/release-chart.yml` |
| Tags de publicación | `chart-vX.Y.Z[-pre]` sobre commits de `main` |
| Emisor de la firma (cosign keyless) | `https://token.actions.githubusercontent.com` |
| Identidad de la firma | `https://github.com/kidcuauh/ci/.github/workflows/release-chart.yml@refs/tags/chart-v<versión>` |
| Selector de los Deployments | `app.kubernetes.io/instance: <release>` y `app.kubernetes.io/component: web` o `worker-<name>` |

Verificar una versión a mano:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/kidcuauh/ci/.github/workflows/release-chart.yml@refs/tags/chart-v1.0.0-rc.1 \
  ghcr.io/kidcuauh/charts/app@sha256:<digest>
```

## Límites de la v1

- Un release = una imagen; sin sidecars ni initContainers.
- Sin `StatefulSet` ni `HorizontalPodAutoscaler`: apps sin estado. Las bases y servicios con estado (caches, buscadores, bases de datos) van como manifiestos planos en `infra/`, fuera del chart.
- El chart no crea `Secret`, `ConfigMap` ni PVC: los ConfigMaps (por ejemplo, con `configMapGenerator`) y los PVC los aporta quien usa el chart; el PVC solo se monta en el web.
- Sin `NetworkPolicy`: la aplica la plataforma.
- Sin TLS en el Ingress (termina en el borde), sin `defaultBackend`, sin anotaciones y sin `HTTPRoute`.
- Sin `exec` en las probes.
- `whenUnsatisfiable` tiene por defecto `ScheduleAnyway`; puede cambiar en una versión futura.
