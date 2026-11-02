#!/usr/bin/env bash
# Digest y retag de imágenes en el registro. Uso:
#   deploy-registry.sh digest IMAGE TAG        imprime el digest; sale 0 si existe,
#                                              3 si no existe, 2 si hubo otro error
#   deploy-registry.sh retag IMAGE DIGEST TAG  pone TAG (X.Y.Z) a IMAGE@DIGEST sin
#                                              reconstruir; un X.Y.Z nunca cambia de digest
# DEPLOY_SLEEP: segundos entre reintentos (5). Requiere docker con buildx y jq.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

die() { # código mensaje
  local code="$1"
  shift
  printf '::error::%s\n' "$*" >&2
  exit "$code"
}

check_image() { [[ "$1" =~ $RE_IMAGE ]] || die 2 "imagen inválida"; }

cmd_digest() { # image tag
  local image="$1" tag="$2" attempt out err d
  check_image "$image"
  [[ "$tag" =~ $RE_SHATAG || "$tag" =~ $RE_SEMVER ]] || die 2 "tag inválido"
  err="$(mktemp)"
  for attempt in 1 2 3; do
    if out="$(docker buildx imagetools inspect "${image}:${tag}" --format '{{json .Manifest}}' 2>"$err")"; then
      d="$(jq -r '.digest // empty' <<<"$out")" || d=""
      [[ "$d" =~ $RE_DIGEST ]] || {
        rm -f "$err"
        die 2 "el registro devolvió un digest inválido"
      }
      rm -f "$err"
      printf '%s\n' "$d"
      return 0
    fi
    if grep -qiE 'not found|manifest[ _]unknown' "$err"; then
      rm -f "$err"
      return 3
    fi
    if ((attempt < 3)); then sleep "${DEPLOY_SLEEP:-5}"; fi
  done
  rm -f "$err"
  die 2 "no se pudo consultar el registro tras 3 intentos"
}

cmd_retag() { # image digest tag
  local image="$1" digest="$2" tag="$3" cur rc got
  check_image "$image"
  [[ "$digest" =~ $RE_DIGEST ]] || die 2 "digest inválido"
  [[ "$tag" =~ $RE_SEMVER ]] || die 2 "el tag debe ser X.Y.Z"
  rc=0
  cur="$(cmd_digest "$image" "$tag")" || rc=$?
  case "$rc" in
    0)
      if [[ "$cur" == "$digest" ]]; then
        echo "el tag ${tag} ya existe con el mismo digest"
        return 0
      fi
      die 1 "el tag ${tag} ya existe con otro digest: un X.Y.Z nunca se reescribe"
      ;;
    3) ;;
    *) die 1 "no se pudo consultar el tag ${tag}" ;;
  esac
  docker buildx imagetools create --prefer-index=false -t "${image}:${tag}" "${image}@${digest}" >&2 ||
    die 1 "no se pudo crear el tag ${tag}"
  rc=0
  got="$(cmd_digest "$image" "$tag")" || rc=$?
  if ((rc != 0)) || [[ "$got" != "$digest" ]]; then
    die 1 "el tag ${tag} no apunta al digest esperado tras el retag (apunta a ${got:-nada}); no lo uses con el botón hasta corregirlo"
  fi
  echo "tag ${tag} creado"
}

case "${1:-}" in
  digest)
    (($# == 3)) || die 2 "uso: deploy-registry.sh digest IMAGE TAG"
    cmd_digest "$2" "$3"
    ;;
  retag)
    (($# == 4)) || die 2 "uso: deploy-registry.sh retag IMAGE DIGEST TAG"
    cmd_retag "$2" "$3" "$4"
    ;;
  *) die 2 "uso: deploy-registry.sh digest|retag ..." ;;
esac
