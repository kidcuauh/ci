#!/usr/bin/env bash
# Versiones vX.Y.Z de un repo. Uso:
#   deploy-version.sh highest --repo DIR   el vX.Y.Z más alto entre los tags (vacío si no hay)
#   deploy-version.sh next --repo DIR      el siguiente patch del más alto, o v1.0.0
#   deploy-version.sh gt A B               sale 0 si A > B (versiones vX.Y.Z)
# Los tags que no cumplen vX.Y.Z (v1, v1.2, v01.0.0...) se ignoran.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

highest() { # repo
  local t best=""
  while IFS= read -r t; do
    [[ "$t" =~ $RE_VERSION ]] || continue
    if [[ -z "$best" ]] || gt "$t" "$best"; then best="$t"; fi
  done < <(git -C "$1" tag -l 'v*')
  printf '%s\n' "$best"
}

gt() { # A B
  local a b
  [[ "$1" =~ $RE_VERSION && "$2" =~ $RE_VERSION ]] || return 2
  a="${1#v}"
  b="${2#v}"
  local IFS=.
  # shellcheck disable=SC2206
  a=($a)
  # shellcheck disable=SC2206
  b=($b)
  local i
  for i in 0 1 2; do
    if ((10#${a[$i]} > 10#${b[$i]})); then return 0; fi
    if ((10#${a[$i]} < 10#${b[$i]})); then return 1; fi
  done
  return 1
}

need_repo() {
  [[ "${1:-}" == --repo && -n "${2:-}" && -d "$2" ]] || fail "uso: deploy-version.sh $cmd --repo DIR"
}

cmd="${1:-}"
case "$cmd" in
  highest)
    need_repo "${2:-}" "${3:-}"
    highest "$3"
    ;;
  next)
    need_repo "${2:-}" "${3:-}"
    h="$(highest "$3")"
    if [[ -z "$h" ]]; then
      echo v1.0.0
    else
      IFS=. read -r ma mi pa <<<"${h#v}"
      echo "v${ma}.${mi}.$((10#$pa + 1))"
    fi
    ;;
  gt)
    (($# == 3)) || fail "uso: deploy-version.sh gt A B"
    gt "$2" "$3"
    ;;
  *) fail "uso: deploy-version.sh highest|next|gt ..." ;;
esac
