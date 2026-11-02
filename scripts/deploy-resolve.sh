#!/usr/bin/env bash
# Qué imagen lleva un Release. Uso:
#   deploy-resolve.sh --repo DIR --commit R --owner O --apps "a b"
#                     [--max-commits 20] [--wait 900] [--interval 30]
# Recorre la historia de R por primer padre y toma el commit C más reciente que tiene
# imagen sha-<12> de todas las apps y solo cambios de infra/ entre C y R. Espera hasta
# --wait segundos a que aparezca (el build de ese commit puede seguir corriendo). Todo
# o nada: o salen todas las apps del mismo C, o ninguna.
# Salida (stdout): "commit <C>" y una línea "<app> <digest>" por app. Sale 0 si
# encontró y 1 si no. Documentación: docs/deploy.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

repo=""
commit=""
owner=""
apps=""
max=20
wait_s=900
interval=30
while (($# > 0)); do
  (($# >= 2)) || fail "argumento sin valor"
  case "$1" in
    --repo) repo="$2" ;;
    --commit) commit="$2" ;;
    --owner) owner="$2" ;;
    --apps) apps="$2" ;;
    --max-commits) max="$2" ;;
    --wait) wait_s="$2" ;;
    --interval) interval="$2" ;;
    *) fail "argumento desconocido" ;;
  esac
  shift 2
done
[[ -d "$repo" ]] || fail "--repo: no es un directorio"
[[ "$commit" =~ $RE_SHA40 ]] || fail "--commit inválido"
[[ "$owner" =~ $RE_OWNER ]] || fail "--owner inválido"
[[ -n "$apps" ]] || fail "--apps vacío"
for a in $apps; do [[ "$a" =~ $RE_NAME ]] || fail "app inválida"; done
for n in "$max" "$wait_s" "$interval"; do [[ "$n" =~ ^[0-9]+$ ]] || fail "número inválido"; done

candidates="$(git -C "$repo" rev-list --first-parent --max-count="$max" "$commit")" ||
  fail "no se pudo leer la historia del commit"

# try: sale 0 e imprime el resultado si todas las apps tienen imagen en un mismo C;
# 1 si no (todavía); 2 si el registro falló.
try() {
  local c out rc d app
  for c in $candidates; do
    if [[ -n "$(git -C "$repo" log --first-parent --format=%H "$c..$commit" -- . ':(exclude)infra')" ]]; then
      return 1
    fi
    out="commit $c"$'\n'
    rc=0
    for app in $apps; do
      d="$(bash "$here/deploy-registry.sh" digest "ghcr.io/$owner/$app" "sha-${c:0:12}")" || rc=$?
      if ((rc == 3)); then break; fi
      if ((rc != 0)); then return 2; fi
      out+="$app $d"$'\n'
    done
    if ((rc == 0)); then
      printf '%s' "$out"
      return 0
    fi
  done
  return 1
}

start=$SECONDS
while :; do
  rc=0
  res="$(try)" || rc=$?
  if ((rc == 0)); then
    printf '%s\n' "$res"
    exit 0
  fi
  if ((rc == 2)); then fail "no se pudo consultar el registro; no se toca prod ni se crea el Release"; fi
  if ((SECONDS - start >= wait_s)); then break; fi
  sleep "$interval"
done
fail "el código del commit no tiene imagen sha- de todas las apps; no se toca prod ni se crea el Release; reintenta con el botón"
