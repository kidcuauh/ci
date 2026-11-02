# build-push.yml

Construye una imagen una vez, la publica en GHCR **por digest y sin tag**, la escanea con Trivy y, solo si pasa, le pone el tag `sha-<12 hex>`. Sin `latest`, sin semver y sin tags flotantes: una imagen sirve a todos los ambientes.

`uses: kidcuauh/ci/.github/workflows/build-push.yml@main`.

## Inputs

| Input | Tipo | Por defecto | Notas |
|---|---|---|---|
| `image-name` | string | nombre del repo que llama, en minúsculas | Sin owner ni registry. Minúsculas, `[a-z0-9._-]`, segmentos separados por `/` |
| `context` | string | `.` | Ruta relativa a la raíz del repo: sin `..` ni `/` inicial |
| `dockerfile` | string | `<context>/Dockerfile` | Ruta desde la raíz del repo, mismas reglas |
| `target` | string | vacío | Etapa del Dockerfile |
| `platforms` | string | `linux/amd64` | **Una sola**: `linux/amd64` o `linux/arm64` (la limpieza asume un manifiesto por imagen) |
| `build-args` | string | vacío | Una `CLAVE=valor` por línea. Ver advertencias |
| `push` | boolean | `true` | `false`: construye a un tar docker y escanea sin publicar, etiquetar ni hacer login |
| `scan-fail-on` | string | `CRITICAL` | `CRITICAL`, `HIGH` o `none` |

Todos los inputs se validan antes de usarse. En un evento `pull_request` con `push: true` el workflow falla (usa `push: false`), y con `pull_request_target` siempre falla.

### Advertencias sobre `build-args`

- **Nunca secretos.** Un build-arg queda en `docker history`. Los secretos van en `BUILD_SECRETS`.
- **Ninguno debe variar por ambiente.** La misma imagen sirve a todos; la configuración por ambiente se resuelve en runtime. Excepción: URLs y tokens públicos, no secretos e iguales en todos los ambientes.

## Secret `BUILD_SECRETS` (opcional)

Líneas `id=valor`. El id es `[a-z0-9_-]+`; el valor va en una sola línea. Si empieza con `base64:` se decodifica (para contenidos multilínea). Cada valor, y cada línea no vacía del contenido decodificado, se enmascara en el log antes de cualquier otro uso. Se escribe en un archivo con permisos `0600` bajo `$RUNNER_TEMP`, se pasa a buildx con `--secret` y se borra al terminar, aunque el job falle.

```yaml
secrets:
  BUILD_SECRETS: |
    npmrc=base64:${{ secrets.NPMRC_B64 }}
    token=${{ secrets.TOKEN_DE_PRUEBA }}
```

En el Dockerfile se consume solo durante el `RUN`, sin dejar rastro en ninguna capa:

```dockerfile
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```

No se admite `secrets: inherit`: se pasa cada secreto por nombre.

## Outputs

| Output | Valor |
|---|---|
| `image` | `ghcr.io/<owner en minúsculas>/<image-name>` |
| `tag` | `sha-<12 hex>`; vacío si no se etiquetó |
| `digest` | `sha256:…` de la imagen construida (también con `push: false`) |
| `ref` | `<image>:<tag>@<digest>`; vacío si no se etiquetó |
| `pushed` | `true` solo si publicó, pasó el escaneo y puso el tag; en cualquier otro caso `false` |

## Permisos

El workflow llamado no puede elevar permisos: el job que lo llama debe declarar

```yaml
permissions:
  contents: read
  packages: write
```

No usa `id-token` ni `attestations`. Con `push: false` no se usa `packages`, pero el job llamado lo pide igual y el caller debe concederlo.

## Escaneo

Trivy (binario de una release con sha256 verificado) revisa la imagen por digest antes de etiquetarla, con los escáneres `vuln` y `secret` e ignorando lo que no tiene corrección:

- Un informe de `HIGH` y `CRITICAL` va siempre al resumen del job.
- La compuerta bloquea según `scan-fail-on`. Si falla, el job falla y la imagen **queda sin tag** (`pushed` = `false`); [cleanup-images](cleanup-images.md) la borra pasados `untagged-days` (7 por defecto).
- Los secretos en capas bloquean con **cualquier severidad** (Trivy clasifica, por ejemplo, `private-key` como HIGH); `scan-fail-on` solo gradúa las vulnerabilidades. Punto ciego de Trivy: ignora rutas que contienen `example`, `/test`, `-test`, `_test` o `.test`, y `usr/(share|include|lib)/`; un secreto ahí no se reporta.
- Riesgo residual: la imagen se publica por digest antes de escanearse. Si falla la compuerta queda en GHCR sin tag y se puede bajar por digest quien tenga lectura del paquete hasta que la limpieza la borre (7 días por defecto).
- `scan-fail-on: none` desactiva la compuerta, no el informe.
- Excepciones: un archivo `.trivyignore` en la raíz del repo que llama se respeta en la compuerta.

Con `push: true` se sube también un SBOM CycloneDX como artefacto del run (`sbom-<image-name>`, 30 días). No hay attestations ni procedencia: la imagen es un único manifiesto.

## Prueba con publicación real

El selftest usa `push: false`, así que no prueba el camino `push: true` (push por digest, `imagetools create`, verificación del digest del tag, login, SBOM y las salidas `pushed` y `ref`). Antes de dar por cerrada una versión de este workflow, corre un `push: true` en un repo desechable con una imagen buena y con la del CVE; comprueba con `docker buildx imagetools inspect` que la buena tiene el tag `sha-` con el digest escaneado y que la mala no tiene tag.

## Caché

Caché de Actions por imagen (`scope=<image-name>`, formato v2), así un monorepo no pisa la de otra imagen. Si se pierde, el build solo tarda más.

## Ejemplos

Llamada directa mínima:

```yaml
jobs:
  build:
    permissions:
      contents: read
      packages: write
    uses: kidcuauh/ci/.github/workflows/build-push.yml@main
```

Servicio simple, desde un workflow de `ci` que decide cuándo construir:

```yaml
jobs:
  build:
    permissions:
      contents: read
      packages: write
    uses: kidcuauh/ci/.github/workflows/build-push.yml@main
    with:
      image-name: mi-app
    secrets:
      BUILD_SECRETS: |
        npmrc=base64:${{ secrets.NPMRC_B64 }}
  siguiente:
    needs: build
    if: needs.build.outputs.pushed == 'true'
    runs-on: ubuntu-26.04
    permissions: {}
    steps:
      - run: echo "${{ needs.build.outputs.ref }}"
```

Monorepo, una imagen por elemento de la matriz:

```yaml
jobs:
  build:
    strategy:
      matrix:
        include:
          - { image: mi-app-api, context: apps/api }
          - { image: mi-app-web, context: apps/web }
    permissions:
      contents: read
      packages: write
    uses: kidcuauh/ci/.github/workflows/build-push.yml@main
    with:
      image-name: ${{ matrix.image }}
      context: ${{ matrix.context }}
```

Un release sobre un commit fuera de `main` (hotfix) funciona igual: se construye el commit del evento.
