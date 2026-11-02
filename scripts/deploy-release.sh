#!/usr/bin/env bash
# Tags y Releases por la API de GitHub (solo `gh api`). Uso:
#   deploy-release.sh create --slug OWNER/REPO --tag vX.Y.Z --sha SHA
#       crea el tag y después el Release (con notas generadas). Sale 0 si lo creó,
#       3 si el tag ya existía (choque con otro run), 1 si falló.
#   deploy-release.sh info --slug OWNER/REPO --tag vX.Y.Z
#       imprime "<draft> <prerelease>"; sale 0 si existe, 3 si no existe, 2 si falló.
# El token es GH_TOKEN (github.token del job, con contents: write). Un Release creado
# con ese token no dispara otro run. DEPLOY_SLEEP: segundos entre reintentos (5).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

cmd="${1:-}"
shift || true
slug=""
tag=""
sha=""
while (($# > 0)); do
  (($# >= 2)) || fail "argumento sin valor"
  case "$1" in
    --slug) slug="$2" ;;
    --tag) tag="$2" ;;
    --sha) sha="$2" ;;
    *) fail "argumento desconocido" ;;
  esac
  shift 2
done
[[ "$slug" =~ $RE_SLUG ]] || fail "--slug inválido"
[[ "$tag" =~ $RE_VERSION ]] || fail "--tag inválido: debe ser vX.Y.Z"

case "$cmd" in
  create)
    [[ "$sha" =~ $RE_SHA40 ]] || fail "--sha inválido"
    if ! out="$(gh api -X POST "repos/$slug/git/refs" -f "ref=refs/tags/$tag" -f "sha=$sha" 2>&1)"; then
      if grep -qE 'Reference already exists' <<<"$out"; then
        warn "el tag $tag ya existe"
        exit 3
      fi
      printf '%s\n' "$out" >&2
      fail "no se pudo crear el tag $tag"
    fi
    for attempt in 1 2 3; do
      if out="$(gh api -X POST "repos/$slug/releases" -f "tag_name=$tag" -f "name=$tag" \
        -F generate_release_notes=true -F draft=false -F prerelease=false 2>&1)"; then
        echo "Release $tag creado"
        exit 0
      fi
      printf '%s\n' "$out" >&2
      if ((attempt < 3)); then sleep "${DEPLOY_SLEEP:-5}"; fi
    done
    fail "el tag $tag quedó creado sin Release: crea el Release a mano sobre ese tag desde la UI (eso promueve)"
    ;;
  info)
    err="$(mktemp)"
    if out="$(gh api "repos/$slug/releases/tags/$tag" 2>"$err")"; then
      rm -f "$err"
      jq -r '"\(.draft) \(.prerelease)"' <<<"$out"
      exit 0
    fi
    if grep -qE 'HTTP 404|Not Found' "$err"; then
      rm -f "$err"
      exit 3
    fi
    cat "$err" >&2
    rm -f "$err"
    exit 2
    ;;
  *) fail "uso: deploy-release.sh create|info ..." ;;
esac
