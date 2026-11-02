# ci

Workflows reutilizables de GitHub Actions para los proyectos de kidcuauh. Los llaman repos de varias orgs, cada uno con sus propios secretos.

## Contrato

- Solo workflows **genéricos**: sin secretos, hostnames ni lógica de negocio.
- Los callers usan siempre `@main`: `uses: kidcuauh/ci/.github/workflows/<archivo>.yml@main`.
- Cada repo pasa sus secretos **por nombre**. `secrets: inherit` no funciona entre orgs y no se usa, ni siquiera dentro de este repo.
- `permissions` mínimos por job: el caller declara lo que el workflow pide.
- Nada de `pull_request_target`.
- Actions de terceros: **hoy están prohibidas**; solo se admiten `actions/*` fijadas por SHA de 40 caracteres. Permitir una (fijada por SHA) exige cuatro cambios coordinados: la regex de `scripts/check-workflows.sh`, `patterns_allowed` en `scripts/apply-protections.sh`, su comprobación en `scripts/verify-protections.sh` y los fixtures de `scripts/tests/`. Los binarios se descargan con sha256 literal verificado antes de ejecutarlos.
- `scripts/check-workflows.sh` es una guardia de texto de mejor esfuerzo (no parsea YAML) que corre en cada PR; la respaldan zizmor y los ajustes de Actions del repo. La atesta el propio workflow del PR, así que frena accidentes, no a un dueño comprometido.
- Las versiones y hashes de actionlint y zizmor en `lint.yml` se actualizan a mano: Dependabot no los ve.

## Workflows

- `build-push.yml`: construye, escanea y publica una imagen en GHCR. Ver [docs/build-push.md](docs/build-push.md).
- `cleanup-images.yml`: retención de versiones de imágenes. Ver [docs/cleanup-images.md](docs/cleanup-images.md).
- `selftest.yml`: prueba `build-push.yml` con `push: false` sobre imágenes de `tests/fixtures/`. Dos de sus jobs fallan a propósito (`imagen-cve`, `imagen-secreto`) y dejan el run en rojo: el check que cuenta es `resultado`.
- `release-chart.yml`: publica el chart `app` en GHCR con un tag `chart-vX.Y.Z` sobre `main`, lo firma con cosign keyless y crea una release inmutable. Ver [docs/release-chart.md](docs/release-chart.md).
- `check-infra.yml`: verifica el `infra/` de un repo que usa el chart `app`, sin cluster ni secretos. Ver [docs/check-infra.md](docs/check-infra.md).
- `chart.yml`: pruebas del chart `app` (`charts/app`), de check-infra y del contenido público del repo (jobs `chart`, `check-infra` y `contenido`). Ver [docs/chart-app.md](docs/chart-app.md).
- `e2e.yml`: prueba en kind del chart publicado con Flux en modo multi-tenant. La lógica está en `tests/e2e/run.sh`.

## Compatibilidad hacia atrás

Nunca se quita ni se renombra un input, un secret ni un output. Los inputs nuevos llevan valor por defecto. Un cambio incompatible va en un archivo nuevo (por ejemplo `build-push-2.yml`) y el viejo se mantiene.

## Riesgo residual de `@main`

Es un riesgo aceptado a cambio de no mantener pines en cada caller:

- Un merge malo o una cuenta comprometida llega a todas las orgs en minutos.
- Un merge roto detiene todos los despliegues.
- La frontera real es la cuenta `kidcuauh`: el ruleset no frena a un token con permiso de administración.

## Protecciones

- Acceso solo del dueño: sin colaboradores, invitaciones ni deploy keys.
- Rulesets `main` (rama) y `tags-v` (tags `v*` y `chart-v*`), sin bypass. En `main`: PR obligatorio (0 aprobaciones, solo squash), checks `lint`, `resultado` (del self-test), `chart` y `contenido` (de `chart.yml`) con la rama al día, commits firmados, historial lineal, sin force-push ni borrado.
- Releases inmutables.
- `GITHUB_TOKEN` de solo lectura; Actions no aprueba PR.
- Actions solo de GitHub y fijadas por SHA; aprobación de workflows de forks para todos los externos.
- Secret scanning con push protection, Dependabot (alertas, updates de seguridad y de Actions) y reporte privado de vulnerabilidades.
- Sin secretos ni variables en el repo.

Los cuerpos de los rulesets están en `.github/rulesets/`.

- **Aplicar:** `scripts/apply-protections.sh` muestra el plan (método, ruta y cuerpo); `--apply` escribe. Es idempotente y usa la sesión de `gh`.
- **Comprobar:** `scripts/verify-protections.sh`. Necesita un token de admin, porque `bypass_actors` solo lo ve un admin; sale 0 si todo está bien, 1 si algo falla y 2 si falta una herramienta o el token no es admin.
- **Pruebas sin red de los dos scripts:** `bash scripts/tests/run.sh`.

## Operación

- **Cambios:** siempre por PR desde una rama, con `lint` en verde, y squash.
- **Commits firmados:** el ruleset revisa también los commits de la rama del PR, así que uno sin firma verificada bloquea el squash aunque GitHub firme el commit final. Firma en local con una llave registrada como *signing key* en la cuenta, o crea los commits de la rama por la API (`createCommitOnBranch` de GraphQL), que GitHub firma. Esa vía no conserva el bit de ejecución: por eso los scripts se llaman con `bash`.
- **Agregar un check obligatorio** (por ejemplo el self-test de un workflow). Un nombre equivocado deja todos los PR en «Expected - waiting» (sin bypass, solo sale con break-glass), así que en este orden:
  1. Fusionar el workflow por PR y dejar que corra al menos una vez.
  2. Leer el nombre real: `gh api repos/kidcuauh/ci/commits/<sha>/check-runs --jq '.check_runs[].name'`. Si el job llama a un workflow reutilizable, el contexto es `job-del-caller / job-reutilizable`; si no, solo el nombre del job.
  3. Solo entonces editar `.github/rulesets/main.json` (con `integration_id` 15368), correr `scripts/apply-protections.sh --apply`, actualizar `EXPECTED_CHECKS` en `scripts/verify-protections.sh` y correr `scripts/verify-protections.sh`.
- **Releases:** siempre como borrador y luego publicar: `gh release create vX.Y.Z --draft` y `gh release edit vX.Y.Z --draft=false`. Con releases inmutables el tag no se mueve ni se reutiliza; no existe un `v1` flotante. Comprobar con `gh release verify vX.Y.Z`. No crear tags `v*` ni `chart-v*` de prueba: `tags-v` impide borrarlos.
  - **Crear un tag `v*` no tiene regla:** puede apuntar a un commit que nunca pasó por PR. Antes de fijar un pin o publicar, comprobar `git merge-base --is-ancestor vX.Y.Z origin/main`.
  - **Si publicar se rechaza** (la regla `update` de `tags-v` no está probada contra la creación del tag al publicar): desactivar `tags-v` con break-glass, quitar `update` de `.github/rulesets/tags-v.json`, de `TAGS_RULE_TYPES` en `scripts/verify-protections.sh` y de la prueba de `scripts/tests/run.sh`, y volver a aplicar y verificar.
- **Rollback:** PR de revert del merge malo.
- **Pin de emergencia en un caller:** `@vX.Y.Z`. La allowlist de la org del caller debe permitir ese ref: agregar temporalmente `kidcuauh/ci/.github/workflows/*@vX.Y.Z` y quitarlo al volver a `@main`.
- **Break-glass** (el único bypass; queda en el security log):
  0. Hace falta un token con permiso de administración del repo (`scripts/verify-protections.sh` también lo necesita).
  1. `gh api repos/kidcuauh/ci/rulesets --jq '.[]|{id,name}'` para el id y `gh api -X PUT repos/kidcuauh/ci/rulesets/<id> -f enforcement=disabled`.
  2. Corregir lo que haga falta.
  3. Volver a `active`: `gh api -X PUT repos/kidcuauh/ci/rulesets/<id> -f enforcement=active` (o `scripts/apply-protections.sh --apply`).
  4. Correr `scripts/verify-protections.sh`.
  5. Revisar el security log de la cuenta.

## Para las orgs que lo usan

La allowlist de Actions de cada org debe permitir `kidcuauh/ci/.github/workflows/*@main` además de las Actions de GitHub. En esos patrones `*` no cruza `/`, así que solo vale la referencia `main`.

## Licencia

MIT.
