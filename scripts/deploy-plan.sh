#!/usr/bin/env bash
# Decide qué hace deploy.yml en este evento: valida las imágenes y los ambientes y
# calcula el modo. Uso: deploy-plan.sh --repo DIR
# DIR es el checkout del repo que llama, en GITHUB_SHA, con historia completa, ramas
# (refs/remotes/origin/*) y tags. Entrada por variables de entorno (nunca se interpola
# nada del contexto en un run:): EVENT_NAME, GITHUB_REF, GITHUB_SHA, REPO_NAME, OWNER,
# IN_IMAGES, IN_VERSION, RELEASE_TAG, RELEASE_PRERELEASE.
# Salidas: mode (none|bump|release-auto|promote), build, matrix, apps, envs, source,
# version, kind (push|button|release|hotfix). Documentación: docs/deploy.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

repo=""
while (($# > 0)); do
  case "$1" in
    --repo)
      (($# >= 2)) || fail "uso: deploy-plan.sh --repo DIR"
      repo="$2"
      shift 2
      ;;
    *) fail "argumento desconocido" ;;
  esac
done
[[ -d "$repo" ]] || fail "--repo: no es un directorio"

event="${EVENT_NAME:-}"
ref="${GITHUB_REF:-}"
sha="${GITHUB_SHA:-}"
case "$event" in
  push | release | workflow_dispatch) ;;
  *) fail "deploy.yml corre solo en push a main, release o workflow_dispatch" ;;
esac
[[ "$sha" =~ $RE_SHA40 ]] || fail "GITHUB_SHA inválido"
owner="$(lower "${OWNER:-}")"
[[ "$owner" =~ $RE_OWNER ]] || fail "owner inválido"

# --- imágenes ---------------------------------------------------------------
in_images="${IN_IMAGES:-}"
matrix='[]'
apps=""
if [[ -z "${in_images//[[:space:]]/}" ]]; then
  name="$(lower "${REPO_NAME:-}")"
  if ! [[ "$name" =~ $RE_NAME ]] || ((${#name} > 53)); then
    fail "el nombre del repo no sirve como nombre de imagen: define el input images"
  fi
  matrix="$(jq -nc --arg n "$name" '[{name: $n, context: ".", dockerfile: "", target: ""}]')"
  apps="$name"
else
  raw="$(printf '%s\n' "$in_images" | yq e -o=json '.' - 2>/dev/null | jq -c '.' 2>/dev/null)" ||
    fail "images no es YAML válido"
  jq -e 'type == "array" and length >= 1 and length <= 20' <<<"$raw" >/dev/null ||
    fail "images debe ser una lista de 1 a 20 elementos"
  jq -e 'all(.[]; type == "object" and ((keys - ["name", "context", "dockerfile", "target"]) | length) == 0
    and has("name") and all(.[]; type == "string"))' <<<"$raw" >/dev/null ||
    fail "cada elemento de images admite solo name, context, dockerfile y target, todos texto, y name es obligatorio"
  count="$(jq 'length' <<<"$raw")"
  i=0
  while ((i < count)); do
    name="$(jq -r ".[$i].name" <<<"$raw")"
    ctx="$(jq -r ".[$i].context // \".\"" <<<"$raw")"
    dfile="$(jq -r ".[$i].dockerfile // \"\"" <<<"$raw")"
    target="$(jq -r ".[$i].target // \"\"" <<<"$raw")"
    if ! [[ "$name" =~ $RE_NAME ]] || ((${#name} > 53)); then
      fail "images: name inválido (minúsculas, números y guiones, hasta 53 caracteres)"
    fi
    for p in "context:$ctx" "dockerfile:$dfile"; do
      pv="${p#*:}"
      if [[ "${p%%:*}" == dockerfile && -z "$pv" ]]; then continue; fi
      [[ "$pv" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "images: ${p%%:*} inválido: solo A-Za-z0-9._/-"
      [[ "$pv" != /* && "$pv" != -* && "$pv" != *..* ]] || fail "images: ${p%%:*} inválido: ruta relativa, sin '..'"
    done
    [[ "$target" =~ ^[A-Za-z0-9._-]*$ ]] || fail "images: target inválido"
    case " $apps " in *" $name "*) fail "images: name repetido" ;; esac
    apps="${apps:+$apps }$name"
    matrix="$(jq -c --arg n "$name" --arg c "$ctx" --arg d "$dfile" --arg t "$target" \
      '. + [{name: $n, context: $c, dockerfile: $d, target: $t}]' <<<"$matrix")"
    i=$((i + 1))
  done
fi

# --- ambientes: las carpetas de infra/overlays/ -----------------------------
od="$repo/infra/overlays"
[[ -d "$od" && ! -L "$od" ]] || fail "falta infra/overlays/ en el repo"
has_prod=0
env_lines=""
while IFS= read -r -d '' p; do
  e="${p##*/}"
  [[ ! -L "$p" ]] || fail "infra/overlays contiene un enlace simbólico"
  [[ -d "$p" ]] || fail "infra/overlays contiene algo que no es una carpeta"
  if ! [[ "$e" =~ $RE_NAME ]] || ((${#e} > 63)); then
    fail "infra/overlays contiene una carpeta con nombre inválido (minúsculas, números y guiones)"
  fi
  if [[ "$e" == prod ]]; then has_prod=1; else env_lines+="$e"$'\n'; fi
done < <(find "$od" -mindepth 1 -maxdepth 1 -print0)
((has_prod)) || fail "falta infra/overlays/prod/"
envs="$(printf '%s' "$env_lines" | LC_ALL=C sort | tr '\n' ' ')"
envs="${envs% }"

# --- evento y modo ----------------------------------------------------------
mode=none
build=false
kind=push
version=""
source_sha="$sha"
case "$event" in
  push)
    [[ "$ref" == refs/heads/main ]] || fail "un push solo despliega desde main"
    build=true
    trailers="$(git -C "$repo" show -s --format=%B "$sha" | git interpret-trailers --parse)"
    if grep -q '^Deploy-Env: ' <<<"$trailers"; then
      mode=none
      build=false
      notice "el commit es un bump de despliegue: no hay nada que hacer"
    elif [[ -n "$envs" ]]; then
      mode=bump
    else
      mode=release-auto
    fi
    ;;
  release)
    tag="${RELEASE_TAG:-}"
    if [[ "${RELEASE_PRERELEASE:-}" == true ]]; then
      notice "un pre-release no hace nada"
    else
      [[ "$tag" =~ $RE_VERSION ]] || fail "el tag del Release debe ser vX.Y.Z"
      r="$(git -C "$repo" rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null)" ||
        fail "el tag del Release no está en el checkout"
      [[ "$r" == "$sha" ]] || fail "el tag del Release no apunta a GITHUB_SHA"
      mode=promote
      version="$tag"
      source_sha="$r"
      if git -C "$repo" merge-base --is-ancestor "$r" refs/remotes/origin/main 2>/dev/null; then
        kind=release
      else
        kind=hotfix
        build=true
      fi
    fi
    ;;
  workflow_dispatch)
    [[ "$ref" == refs/heads/main ]] || fail "el botón corre en main"
    v="${IN_VERSION:-}"
    if [[ -n "$v" ]]; then [[ "$v" =~ $RE_VERSION ]] || fail "version inválida: debe ser vX.Y.Z o vacía"; fi
    mode=promote
    kind=button
    version="$v"
    ;;
esac

set_output mode "$mode"
set_output build "$build"
set_output matrix "$matrix"
set_output apps "$apps"
set_output envs "$envs"
set_output source "$source_sha"
set_output version "$version"
set_output kind "$kind"

summary "## deploy"
summary ""
summary "- evento: \`$event\`, modo: \`$mode\`, tipo: \`$kind\`"
summary "- imágenes: \`$apps\`"
summary "- ambientes que no son prod: \`${envs:-ninguno}\`"
if [[ -n "$version" ]]; then summary "- versión pedida: \`$version\`"; fi
exit 0
