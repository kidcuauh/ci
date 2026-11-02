#!/usr/bin/env bash
# Bump de los ambientes que no son prod: cada app, con el tag sha-<12> del commit
# construido y su digest, en todos los ambientes. Uso:
#   deploy-nonprod.sh --repo DIR --source SHA --owner O --apps "a b" --envs "dev qa"
#                     [--check-infra SCRIPT [--check-infra-arg ARG]...]
# Las imágenes deben existir todas: el build de este run las publicó. Aplica la guarda
# de orden (no retrocede un ambiente a un commit más viejo). Sus salidas son las de
# deploy-bump.sh. Documentación: docs/deploy.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

repo=""
source_sha=""
owner=""
apps=""
envs=""
pass=()
while (($# > 0)); do
  (($# >= 2)) || fail "argumento sin valor"
  case "$1" in
    --repo) repo="$2" ;;
    --source) source_sha="$2" ;;
    --owner) owner="$2" ;;
    --apps) apps="$2" ;;
    --envs) envs="$2" ;;
    --check-infra) pass+=("$1" "$(abspath "$2")") ;;
    --check-infra-arg) pass+=("$1" "$2") ;;
    *) fail "argumento desconocido" ;;
  esac
  shift 2
done
[[ "$source_sha" =~ $RE_SHA40 ]] || fail "--source inválido"
[[ "$owner" =~ $RE_OWNER ]] || fail "--owner inválido"
[[ -n "$apps" ]] || fail "--apps vacío"
for a in $apps; do [[ "$a" =~ $RE_NAME ]] || fail "app inválida"; done
for e in $envs; do [[ "$e" =~ $RE_NAME && "$e" != prod ]] || fail "ambiente inválido"; done

if [[ -z "$envs" ]]; then
  notice "no hay ambientes que no sean prod"
  set_output changed false
  exit 0
fi

tag="sha-${source_sha:0:12}"
sets=()
digests=""
for app in $apps; do
  rc=0
  d="$(bash "$here/deploy-registry.sh" digest "ghcr.io/$owner/$app" "$tag")" || rc=$?
  ((rc == 0)) || fail "falta la imagen $app:$tag en el registro: el build de este run debía publicarla"
  digests+="$app $d"$'\n'
done
for e in $envs; do
  for app in $apps; do
    d="$(awk -v a="$app" '$1 == a { print $2 }' <<<"$digests")"
    sets+=(--set "$e" "$app" "$tag" "$d")
  done
done

exec bash "$here/deploy-bump.sh" --repo "$repo" --source "$source_sha" --order-guard \
  "${sets[@]}" ${pass[@]+"${pass[@]}"}
