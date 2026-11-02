# deploy.yml

Entrada única de cada repo de app. Construye **una vez** cada imagen, la despliega en los ambientes que no son prod y promueve a prod con un Release `vX.Y.Z`, sin reconstruir. Escribe la imagen nueva en `infra/` del repo que llama, con un commit; el cluster la aplica desde ahí. El repo muestra siempre qué se quiere correr: cada overlay lleva tag y digest, y cada cambio es un commit con trailers.

`uses: kidcuauh/ci/.github/workflows/deploy.yml@main`. Orquesta [build-push.yml](build-push.md) (hay tres niveles de anidamiento: el caller, `deploy.yml` y `build-push.yml`).

`deploy.yml` llama a `build-push.yml` por su ruta completa en `@main` (`kidcuauh/ci/.github/workflows/build-push.yml@main`), no con `./`. En una prueba real (2026-11-01), la allowlist de Actions de la org que llama evaluó la ruta local anidada como `kidcuauh/ci/.github/workflows/build-push.yml@<SHA>` y la rechazó, porque solo admite `@main`: el run terminó en `startup_failure`. No vuelvas a `./`.

Consecuencias:

- Un pin de emergencia de `deploy.yml` en `@vX.Y.Z` sigue usando el `build-push.yml` de `main`. Un `build-push.yml` malo en `main` se arregla con un revert, no con un pin.
- Además de sus inputs y outputs, `build-push.yml` tiene un contrato con los scripts de `deploy.yml`: la imagen es `ghcr.io/<owner en minúsculas>/<name>` y el tag es `sha-<12 hex>` del commit construido. Cambiar cualquiera de los dos rompe `deploy.yml`.
- actionlint no lee un workflow remoto. `scripts/tests/deploy-tests.sh` comprueba que cada `with` y cada secreto que `deploy.yml` le pasa existen en `build-push.yml`, y que van todos sus inputs obligatorios.

## La regla

1. Todo se integra en `main`. Cada push a `main` que toca algo fuera de `infra/` construye **una vez** cada imagen del repo (`sha-<12>`, escaneada).
2. Cada build va a todos los ambientes que no son prod: las carpetas `infra/overlays/<env>/` distintas de `prod` (hoy, `dev`). Si solo existe `prod`, el build va directo a prod.
3. Prod siempre lleva un Release `vX.Y.Z`: la imagen ya construida recibe el tag `X.Y.Z` (mismo digest) y se escribe en `infra/overlays/prod/`. Sin ambientes intermedios, cada merge crea su Release solo. Con ellos, prod se publica con un botón (`workflow_dispatch`, input `version`).
4. El cluster aplica `main` en todos los ambientes; lo que cambia la imagen es el commit del bump.
5. Rollback: el botón con una versión anterior, o `git revert` del commit del bump.

La regla se decide por repo, no por app. Agregar o quitar `infra/overlays/dev/` cambia el destino del siguiente merge sin tocar el caller.

## El `deploy.yml` del repo

Es el mismo en todos los repos:

```yaml
name: deploy

on:
  push:
    branches: [main]
    paths-ignore: ["infra/**"]
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      version:
        description: "vX.Y.Z (vacío = HEAD de main con la siguiente versión; una existente = volver a desplegarla)"
        required: false
        default: ""

permissions: {}

jobs:
  deploy:
    permissions:
      contents: write # el bump, el tag y el Release
      packages: write # publicar la imagen y su tag X.Y.Z
    uses: kidcuauh/ci/.github/workflows/deploy.yml@main
    secrets:
      BUILD_SECRETS: ${{ secrets.BUILD_SECRETS }} # opcional; ver build-push.md
      push_token: ${{ secrets.DEPLOY_PUSH_TOKEN }} # opcional; ver «Rama protegida»
```

Un secreto que el repo no tiene llega vacío, así que el archivo es igual en todos.

Solo se agrega `with:` en estos casos:

```yaml
    with:
      # Un monorepo: una entrada por imagen. El nombre es la imagen y el archivo de patch.
      images: |
        - name: mi-app-api
          context: apps/api
        - name: mi-app-web
          context: apps/web
          dockerfile: apps/web/web.Dockerfile
          target: runtime
      scan-fail-on: none # CRITICAL (por defecto), HIGH o none
      build-args: |
        API_URL=https://api.example.com
```

Los secretos se pasan por nombre, como en `build-push.yml`. No se usa `secrets: inherit`.

## Qué hace según el evento

| Evento | Qué pasa |
|---|---|
| Push a `main` (fuera de `infra/`) con ambientes que no son prod | Construye y escribe `sha-<12>` y el digest en cada uno. Prod no se toca |
| Push a `main` sin ellos | Construye, crea el Release (siguiente patch; `v1.0.0` si es el primero) sobre ese commit, re-etiqueta `X.Y.Z` y escribe prod, todo en el mismo run |
| Botón con `version` vacía | Toma HEAD de `main`, resuelve su imagen (abajo) y crea el Release con el siguiente patch. Si esa imagen ya está en prod, no crea Release ni commit |
| Botón con un `vX.Y.Z` nuevo | Igual, con ese número (para una minor o una major). Debe ser mayor que el más alto |
| Botón con un `vX.Y.Z` existente | Vuelve a desplegar su digest (rollback). El Release debe existir y no ser borrador ni pre-release |
| Release publicado a mano | Promueve su commit. Un pre-release no hace nada, y un tag suelto no dispara nada |
| Release sobre un commit fuera de `main` | Hotfix: es el único caso en que un Release construye. Ver «Hotfix» |
| Commit de un bump (trae el trailer `Deploy-Env`) | No hace nada |
| `pull_request`, `pull_request_target` u otro | Falla |

## Qué imagen lleva un Release

Sea R el commit del Release. Se recorre su historia por primer padre (hasta 20 commits) y se toma el más reciente C que tiene imagen `sha-<12>` de **todas** las apps del repo y entre C y R solo cambios en `infra/`. No se lee el overlay de ningún ambiente. Si el código aún no tiene imagen (el build sigue corriendo o falló), espera hasta 15 minutos; si no aparece, falla **sin tocar prod y sin crear el tag ni el Release**: se reintenta con el botón. Un Release cubre todas las imágenes del repo o ninguna.

El Release crea primero el tag y el Release, y luego re-etiqueta (`docker buildx imagetools create`, mismo digest). El run comprueba que el digest no cambió y **nunca reescribe un `X.Y.Z`**: si ya existe con otro digest, falla antes de crear nada. Todo semver se conserva (la limpieza de imágenes no lo borra). Con el botón y una versión que ya existe, el registro manda (un rollback usa el digest que prod ya tuvo); si la imagen `sha-` actual del commit trae otro digest, avisa en vez de fallar. En un Release nuevo (a mano, hotfix o automático), un `X.Y.Z` del registro con otro digest que el de la imagen del commit falla siempre.

Si dos runs chocan al crear el mismo tag, el segundo recalcula la siguiente versión. Si el tag se creó pero el Release no, el job lo dice: crea el Release a mano sobre ese tag desde la UI, y eso promueve.

## Entradas, secretos y salidas

| Input | Por defecto | Notas |
|---|---|---|
| `images` | vacío | Lista YAML de hasta 20 elementos; claves `name` (obligatoria, DNS-1123, hasta 53), `context` (`.`), `dockerfile` (`<context>/Dockerfile`) y `target`. Vacío = una imagen con el nombre del repo en minúsculas |
| `build-args` | vacío | Se pasa a `build-push.yml`. Nunca secretos |
| `scan-fail-on` | `CRITICAL` | Se pasa a `build-push.yml` |

La versión del botón no es un input del workflow: se lee del evento del caller (`github.event.inputs.version`).

| Secreto | Notas |
|---|---|
| `BUILD_SECRETS` | Opcional; se pasa a `build-push.yml` |
| `push_token` | Opcional; una llave SSH privada (deploy key de escritura) o un token. Ver «Rama protegida» |

| Output | Valor |
|---|---|
| `changed` | `true` si el run escribió un commit en `infra/` |
| `commit_sha` | Commit empujado a `main` (vacío si no hubo cambio) |
| `previous_digest` | Una línea `<ambiente>/<app> <digest>` por app escrita, con el digest que había |
| `new_digest` | Lo mismo, con el digest nuevo |
| `version` | `vX.Y.Z` promovida a prod (vacío si el run no promovió) |

## Contrato con el repo

- **Archivo:** `infra/overlays/<env>/<app>.patch.yaml`, un solo documento `HelmRelease`. `<app>` es el nombre de la imagen. Las claves `.spec.values.image.tag` y `.spec.values.image.digest` **deben existir**; se editan con `yq`. Una carpeta de ambiente sin patch de la app se omite con aviso (salvo `prod`, que falla). Nada de lo que se escribe puede ser un enlace simbólico.
- **Tags:** fuera de prod, `sha-<12>`; en prod, `X.Y.Z` (sin `v`), siempre entre comillas dobles. El digest va siempre (los tags de GHCR son mutables).
- **Validación antes de empujar:** `kubectl kustomize infra/overlays/<env>` debe mostrar el tag y el digest nuevos en el HelmRelease; después corre [check-infra](check-infra.md) sobre el repo. Si algo falla, no se empuja nada. En prod el número vX.Y.Z se reclama (tag, Release y retag) **antes** de esta verificación y del push: si fallan, ese Release queda publicado sin desplegar. Re-ejecutar el mismo commit lo reutiliza (se termina ese despliegue) en vez de gastar otro número; si el commit no se reintenta, el Release queda huérfano y se puede borrar a mano. Un `main` con ruleset y sin `push_token` publica un Release por merge que no llega a prod hasta configurarlo.
- **Commit:** autor y committer `github-actions[bot]`, solo ese archivo, un commit por app y ambiente (todos en un push, sin force):

  ```
  deploy(<env>): <app> -> <tag> [skip ci]

  Deploy-Env: <env>
  Deploy-App: <app>
  Image-Tag: <tag>
  Image-Digest: <digest>
  Source-SHA: <commit>
  Previous-Tag: <tag anterior>
  Previous-Digest: <digest anterior>
  ```

  `Source-SHA` es el commit construido en los ambientes que no son prod, y el commit del Release en prod.
- **Ambientes:** son las carpetas de `infra/overlays/` (nombre DNS-1123). `prod` debe existir. Un nombre inválido, un archivo suelto o un enlace simbólico ahí hacen fallar el plan.

## Rollback

- **El botón** con una versión anterior (`v1.2.3`): deja prod con el tag y el digest de esa versión en un solo commit con `Previous-Tag` y `Previous-Digest`. Tarda lo que el job más lo que el cluster tarde en reconciliar.
- **`git revert` del commit del bump:** sirve si no hubo bumps posteriores sobre las mismas líneas; si los hubo, usa el botón.
- **Límites:** la imagen debe seguir en el registro (todo semver se conserva) y **no se revierten migraciones de datos**.
- **Repos sin ambientes intermedios:** tras un rollback con el botón, el siguiente merge a `main` vuelve a publicar `main`. Arregla o revierte el código en seguida.

## Hotfix

Con ambientes intermedios, un hotfix es un Release: una rama `hotfix/<x>` desde el tag que corre en prod (lleva el `deploy.yml`) y `gh release create vX.Y.Z --target hotfix/<x>`. Como ese commit no está en `main` y no tiene imagen, el Release **construye una vez**: es el único caso. Después re-etiqueta y escribe el overlay `prod` de `main`; el de los demás ambientes no se toca. El PR con el arreglo a `main` va después. Un tag suelto no dispara nada.

Sin ambientes intermedios, un hotfix es un merge a `main`.

## Agregar o quitar un ambiente

Los ambientes son las carpetas de `infra/overlays/`. El alta del ambiente en la plataforma (su namespace y su Kustomization de Flux) va **antes** de la carpeta: si la carpeta llega primero, el bump escribe un overlay que nadie aplica. Agregar `infra/overlays/dev/` cambia el destino del siguiente merge (ahora dev, y prod espera al botón) sin tocar el caller; borrarla lo devuelve a prod directo. Cuando se quita un ambiente, retira primero su Kustomization.

## Rama protegida

- **Sin protección forzada** (por ejemplo, un repo privado en un plan gratuito): el `GITHUB_TOKEN` empuja directo a `main` sin ajustes. Con él, el push no crea runs nuevos.
- **Con un ruleset** que exige PR o checks en `main`: el `GITHUB_TOKEN` no puede saltarlo y el push falla con un mensaje que remite a esta sección («configura el secreto `push_token`»). Crea una **deploy key de escritura** en el repo, agrégala como actor de bypass del ruleset y guarda la llave privada en el secreto `DEPLOY_PUSH_TOKEN`. El workflow la detecta (empieza con `-----BEGIN`), empuja por SSH con host key verificada y la borra al terminar. Un token HTTPS también sirve en ese secreto. La credencial nunca se escribe en `.git/config`.
- Si la deploy key no sirviera como actor de bypass, la alternativa es una GitHub App, y pide un cambio en este repo.
- Un push con `push_token` sí puede crear runs: lo evitan `[skip ci]`, el `paths-ignore: infra/**` del caller y el plan, que se salta un commit con el trailer `Deploy-Env`.

## Concurrencia y carreras

- **Ambientes que no son prod, sin grupo de `concurrency`.** GitHub conserva un solo job pendiente por grupo y descarta al anterior aunque sea más nuevo, y los jobs se encolan cuando termina su build, no en el orden de los commits: con un grupo, un pendiente más viejo podría reemplazar a uno más nuevo y dejar el ambiente atrás. Sin grupo, los bumps corren a la vez, empujan sobre la punta fresca de `main` y la guarda de orden omite al más viejo.
- **Prod, en serie por repo** (grupo `infra-bump-<repo>-prod`, `cancel-in-progress: false`): cada promoción ve el tag y el overlay que dejó la anterior, así la numeración sigue el orden del código y un build más viejo que el que ya llegó se salta **sin crear Release**. Límite conocido: si llega una tercera promoción mientras otra espera, GitHub cancela la que esperaba; si la cancelada era la más nueva, prod queda en la anterior hasta el siguiente merge. Vuelve a lanzar el run cancelado o usa el botón con la versión vacía.
- Un push rechazado por carrera se reintenta hasta 5 veces desde la punta fresca de `main`, reevaluando todo.
- En los ambientes que no son prod, si el `Source-SHA` del último bump ya es igual o más nuevo que el commit del run, ese ambiente se omite con aviso (no retrocede). En prod, el Release automático hace la misma comprobación antes de reclamar la versión y otra vez al empujar.
- Un bump sin cambio deja `changed=false` y no hace commit.

## Ciclos

Un push con `GITHUB_TOKEN` no crea runs. Con `push_token` sí, y por eso hay tres cortes: `[skip ci]` en el asunto, el `paths-ignore: infra/**` del caller y la guarda por contenido del plan (un commit con el trailer `Deploy-Env` no hace nada, sea quien sea el actor). Re-ejecutar el mismo commit no crea otro bump.

## Decisiones

- **Flux image automation, descartada:** pide una deploy key con escritura en cada repo y credenciales del registro en el cluster; la plataforma no guarda ninguna.
- **Prod sigue `main`:** un cambio de manifiestos llega a prod sin Release; solo la imagen pasa por la puerta. Si duele, una rama o un tag `prod` lo cambia (y cambia la plataforma).
- **Promover no reconstruye:** se resuelve la imagen y se re-etiqueta con el mismo digest.
- **No hay PR de promoción** ni un archivo de ambientes (sería una segunda fuente de verdad).
- **Estado deseado vs aplicado:** el repo muestra lo que se quiere correr. Si el cluster no puede aplicarlo, el repo dice una versión y el cluster corre otra. Cerrar ese hueco pide una notificación del cluster al repo (un commit status) y un token por repo; hoy no está.
- **Sin Actions de terceros para el semver:** la siguiente versión es el siguiente patch del `vX.Y.Z` más alto (ignora tags como `v1` o `v1.2`); una persona escribe el número solo para una minor o una major.

## Scripts y pruebas

La lógica está en `scripts/deploy-*.sh` (`plan`, `resolve`, `version`, `registry`, `release`, `bump`, `nonprod`, `promote` y `lib`), invocados con `bash` y con todo valor del contexto por variables de entorno. `bash scripts/tests/deploy-tests.sh` los prueba sin red, con un `docker` y un `gh` falsos y un origin git local, y corre en cada PR (`deploy-tests.yml`). Necesita `git`, `jq`, `yq` y `kubectl`.

**Pendiente:** la prueba real contra GitHub y GHCR, en un repo desechable con ambientes intermedios y otro sin ellos (y uno público con ruleset para la rama protegida), como describe [build-push.md](build-push.md) para su caso. Las pruebas sin red no cubren el comportamiento real del ruleset ni de los permisos del `GITHUB_TOKEN`.
