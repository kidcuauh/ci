# release-chart.yml

Publica el chart `app` como artefacto OCI en GHCR, lo firma con cosign (keyless) y crea una release inmutable. El chart vive en `charts/app` y se consume **por digest**: los tags de GHCR son mutables y este workflow nunca sobrescribe una versión.

## Contrato (no cambia sin un cambio mayor para todos los consumidores)

| Elemento | Valor |
|---|---|
| Chart | `oci://ghcr.io/kidcuauh/charts/app` |
| Workflow | `.github/workflows/release-chart.yml` |
| Disparador | tag `chart-vX.Y.Z` o `chart-vX.Y.Z-<pre>` sobre un commit de `main` |
| Issuer de la firma | `https://token.actions.githubusercontent.com` |
| Subject de la firma | `https://github.com/kidcuauh/ci/.github/workflows/release-chart.yml@refs/tags/chart-v<versión>` |

Expresiones regulares que usa un consumidor en `verify.matchOIDCIdentity` de su `OCIRepository`:

```yaml
issuer: ^https://token\.actions\.githubusercontent\.com$
subject: ^https://github\.com/kidcuauh/ci/\.github/workflows/release-chart\.yml@refs/tags/chart-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$
```

## Cómo publicar

1. Sube la versión en `charts/app/Chart.yaml` (campo `version`, SemVer) y mergea el cambio a `main` por PR.
2. Crea el tag **ligero** sobre el commit de `main` con la API, sin identidad de commiter ni clon local:

   ```bash
   gh api repos/kidcuauh/ci/git/refs \
     -f ref=refs/tags/chart-vX.Y.Z \
     -f sha=<sha completo del commit de main>
   ```

3. Empuja **un solo tag `chart-v*` a la vez** y espera a que termine el run antes del siguiente: `concurrency` mantiene un run en curso y uno pendiente, y un tag intermedio se cancelaría sin publicar.
4. El push del tag dispara el workflow. La primera vez, el paquete de GHCR nace privado: hay que hacerlo público desde la configuración del paquete para que `helm pull` anónimo funcione.

Una versión con guion (`1.0.0-rc.1`) se marca como prerelease.

## Quién puede publicar

La comprobación «el commit del tag está en `main`» es una guarda de conveniencia, no una barrera: un push de tag ejecuta el workflow del propio commit etiquetado, así que quien pueda crear tags `chart-v*` sobre otra rama puede editar el workflow, saltarse esa comprobación y obtener una firma con la identidad del contrato. **El control de acceso es quién puede crear tags**: en este repo, solo la cuenta dueña (sin colaboradores ni deploy keys). Una regla de creación con bypass para el administrador no agregaría nada, porque ese administrador es la misma cuenta. El ruleset `tags-v` (`.github/rulesets/tags-v.json`) cubre `chart-v*` igual que `v*`: no se borran, no se mueven y no se reescriben; `scripts/verify-protections.sh` lo comprueba. Además, el job `release` falla si el tag ya no apunta al commit que se verificó y publicó.

## Qué comprueba

Tres jobs en cadena; cada uno solo tiene los permisos que necesita.

| Job | Permisos | Qué hace |
|---|---|---|
| `verificar` | `contents: read` | El tag tiene la forma `chart-vX.Y.Z[-pre]`; la `version` de `Chart.yaml` es igual al tag sin `chart-v`; el commit del tag es ancestro de `origin/main`; pasa `scripts/test-chart.sh` |
| `publicar` | `contents: read`, `packages: write`, `id-token: write` (solo aquí) | La versión **no existe** en GHCR (404 sigue; cualquier otra respuesta falla); `helm package`; `helm push`; lee el digest de la salida; `cosign sign` del digest (formato clásico, ver más abajo); `cosign verify` con la identidad exacta del contrato |
| `release` | `contents: write` (solo aquí) | Comprueba que el tag sigue apuntando al commit publicado; busca una release previa (borrador incluido) en la lista de releases; crea la release como borrador con `--verify-tag`, con notas (versión, referencia por digest, `helm pull` y `cosign verify`) y la publica al final: una release publicada es inmutable |

Las Actions van fijadas por SHA, los inputs pasan por `env:` y el workflow no usa `secrets: inherit` ni `pull_request_target`. Una ejecución en curso no se cancela (`concurrency` sin `cancel-in-progress`).

## Si falla

- **Antes de publicar** (`verificar` o la comprobación de `publicar`): corrige la causa en `main` y publica con la versión siguiente (`X.Y.Z+1` o el siguiente `-rc.N`). Un tag que no publicó nada queda sin usar. Con `chart-v*` en el ruleset un tag no se puede borrar ni mover; borrarlo exige quitar la regla temporalmente un administrador.
- **Después de publicar** (falla `release`): la versión ya está en GHCR y firmada, y no se puede volver a publicar. Re-ejecuta **solo el job `release`** desde la pestaña Actions («Re-run failed jobs»); es idempotente: completa un borrador que haya quedado y no hace nada si la release ya está publicada.
- **Falla `cosign sign` o `cosign verify`**: la versión ya está en GHCR sin firma válida y el workflow se niega a repetirla. Publica una versión nueva (`X.Y.Z+1` o el siguiente `-rc.N`) y no uses el digest huérfano.

## Formato de la firma y primera publicación

- **Formato de la firma.** cosign 3 firma por defecto en formato bundle. El workflow firma con `--new-bundle-format=false --use-signing-config=false` (firma clásica, etiqueta `<digest>.sig`) porque es lo que lee `verify.provider: cosign` del source-controller de Flux. La compatibilidad con el formato bundle no está comprobada: la decisión definitiva sale del e2e con `1.0.0-rc.1` (con la versión de Flux de la plataforma). Si Flux acepta el bundle, se puede quitar los dos flags; si no acepta ninguno, se fija cosign 2.x.
- **Existencia en GHCR.** `publicar` consulta `GET /v2/kidcuauh/charts/app/manifests/<versión>` y solo sigue con 404. En la primera publicación el paquete aún no existe y GHCR podría contestar 401 o 403 en lugar de 404: el job falla cerrado (no publica nada). Se comprueba con `1.0.0-rc.1`; si pasa, se anota aquí la respuesta observada y, si hace falta, se cambia a la API de Packages (`packages: read`).

## Cómo verificar una versión publicada

Con el digest que da la release (o la salida del job `publicar`):

```bash
# Descarga anónima por digest (el paquete es público)
helm pull oci://ghcr.io/kidcuauh/charts/app@sha256:<digest>

# Firma keyless con la identidad de release-chart.yml
cosign verify \
  --certificate-identity "https://github.com/kidcuauh/ci/.github/workflows/release-chart.yml@refs/tags/chart-v<versión>" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/kidcuauh/charts/app@sha256:<digest>
```

Un consumidor no usa estos comandos a mano: su `OCIRepository` fija el digest y verifica con `verify.provider: cosign` y las expresiones de arriba.

# chart.yml y la guardia de contenido público

`chart.yml` corre en cada PR y en cada push a `main` con tres jobs de nombre estable:

| Job | Qué corre |
|---|---|
| `chart` | `scripts/test-chart.sh` |
| `check-infra` | `scripts/test-check-infra.sh` |
| `contenido` | `scripts/tests/public-content-tests.sh` y `scripts/check-public-content.py` sobre el árbol; en un PR también el título, el cuerpo y los commits (mensajes y correos de autor y committer, que solo pueden ser de `noreply` de GitHub) |

Este repo es público. `scripts/check-public-content.py` (python3, sin red) falla si encuentra:

- un dominio cuyo TLD está en la lista pública de IANA (`scripts/public-content/tlds.txt`) y que no está en la lista de dominios públicos, o un owner de `ghcr.io`, `github.com` u otro registro fuera de la lista de permitidos;
- un correo (salvo `noreply` y `example.*`), un UUID o un ID hex de 32, una IPv4 o IPv6 que no sea de loopback ni de documentación, una ruta local o una referencia interna numerada;
- con `--names ARCHIVO`, un nombre de una lista privada. Esa lista nunca va en el repo: una lista pública, aunque fuera de hashes, serviría para confirmar nombres adivinados. En CI corren solo las reglas genéricas; la lista privada se usa en local antes de empujar. Con `--names`, un archivo ausente o vacío sale con 2.

El informe da archivo, línea y motivo, y no imprime el texto encontrado (`--show-tokens` lo muestra al correrlo en local).
