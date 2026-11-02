# cleanup-images.yml

Retención de versiones de imágenes en GHCR. Arranca en **dry-run**: solo escribe en el resumen del job lo que borraría.

## Inputs

| Input | Tipo | Por defecto | Notas |
|---|---|---|---|
| `image-names` | string | nombre del repo | Nombres separados por coma, sin owner |
| `keep-last` | number | `20` | Versiones con tag `sha-*` más recientes que se conservan |
| `keep-days` | number | `14` | Toda versión con tag más joven que esto se conserva |
| `untagged-days` | number | `7` | Las sin tag con esta edad o más se borran |
| `infra-path` | string | `infra` | Directorio del repo cuyos archivos protegen digests y tags. Vacío desactiva esa protección, de forma explícita |
| `dry-run` | boolean | `true` | `false` borra |
| `max-deletions` | number | `200` | Tope por imagen: si los candidatos lo superan, falla sin borrar |

Permisos del job que lo llama: `contents: read` y `packages: write`.

## Qué se conserva

1. La versión más reciente del paquete.
2. Todo tag semver (`X.Y.Z` o `vX.Y.Z`, con sufijo opcional `-rc.1` o `+build`), siempre.
3. Toda versión cuyo digest o alguno de sus tags (palabra completa; el digest también sin el prefijo `sha256:`) aparezca en un archivo bajo `infra-path`, leído de la rama por defecto.
4. Las `keep-last` versiones con tag `sha-*` más recientes.
5. Toda versión con tag más joven que `keep-days`.

Se borran las demás con tag y las **sin tag** de `untagged-days` o más. Las sin tag se rigen solo por `untagged-days` (son las que deja un escaneo fallido de [build-push](build-push.md)), salvo que sean la más reciente o estén referenciadas en `infra-path`.

El workflow falla, sin borrar, si `infra-path` no existe en la rama por defecto (un typo no desactiva la protección), si la API devuelve algo con forma inesperada o si el conjunto protegido queda vacío.

## Requisitos

- El paquete debe contener **solo imágenes de un manifiesto** (las de `build-push`). GHCR lista como versiones sin tag los manifiestos por plataforma y las attestations de un índice multi-arch; esta limpieza los borraría pasados `untagged-days` y rompería al índice, aunque el índice esté protegido.
- Los enlaces simbólicos bajo `infra-path` se siguen. Si el directorio existe pero no aporta texto, el script avisa en el resumen del job (stderr) y no hay protección por referencias.
- El paquete debe estar **enlazado al repo que llama**. Los que publica `build-push` con su `GITHUB_TOKEN` lo están; uno creado con un PAT se enlaza en *Manage Actions access* del paquete.
- El repo que llama agenda su propio `schedule`.
- Corre primero con `dry-run: true`, revisa la tabla del resumen y solo entonces pasa a `false`.

## Ejemplo

```yaml
name: limpieza-imagenes
on:
  schedule:
    - cron: "17 4 * * 1"
  workflow_dispatch:

permissions: {}

jobs:
  cleanup:
    permissions:
      contents: read
      packages: write
    uses: kidcuauh/ci/.github/workflows/cleanup-images.yml@main
    with:
      image-names: mi-app-api,mi-app-web
      dry-run: true # cambiar a false tras revisar un dry-run
```

Si el caller pasa los umbrales desde inputs de `workflow_dispatch`, conviértelos con `fromJSON`: esos inputs llegan como texto y `workflow_call` espera números («Unexpected value '20'»).

```yaml
    with:
      keep-last: ${{ fromJSON(inputs.keep-last) }}
```
