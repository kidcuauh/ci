#!/usr/bin/env bash
# Guardia sin red sobre los workflows. Uso: check-workflows.sh [directorio]
# Falla (exit 1) con un mensaje por problema.
# Es una guardia de texto de mejor esfuerzo (grep), no un parser de YAML: frena
# accidentes y las formas comunes de `uses:`/`permissions:`. Los respaldos reales
# son zizmor en el job lint y los ajustes del repo (SHA obligatorio, allowlist
# sin patrones). Lo atesta el propio workflow del PR: no frena a un dueño
# comprometido, que puede editar la guardia.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${1:-$root/.github/workflows}"
errors=0

err() {
  printf 'ERROR %s\n' "$*" >&2
  errors=$((errors + 1))
}

shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
if ((${#files[@]} == 0)); then
  err "no hay workflows en $dir"
  printf '%d problema(s) en los workflows\n' "$errors" >&2
  exit 1
fi
# Con el directorio por defecto también se revisan las acciones compuestas locales.
extra=()
if [[ $# -eq 0 ]]; then
  extra=("$root"/.github/actions/*/action.yml "$root"/.github/actions/*/action.yaml)
fi

for f in "${files[@]}" ${extra[@]+"${extra[@]}"}; do
  # 1. uses: solo local o actions/* fijado por SHA de 40 hex
  while IFS= read -r line; do
    n="${line%%:*}"
    v="${line#*:}"
    v="$(printf '%s' "$v" | sed -E 's/^.*["'"'"']?uses["'"'"']?[[:space:]]*:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]*[},].*$//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//')"
    if [[ "$v" =~ ^\./ ]] || [[ "$v" =~ ^actions/[A-Za-z0-9._-]+(/[A-Za-z0-9._/-]+)?@[0-9a-f]{40}$ ]]; then
      continue
    fi
    err "$f:$n: uses '$v' no es local ni actions/* fijado por SHA de 40 caracteres"
  done < <(grep -nE '(^|[[:space:]{,-])["'"'"']?uses["'"'"']?[[:space:]]*:' "$f" || true)

  # 2. nada de pull_request_target
  while IFS= read -r line; do
    err "$f:${line%%:*}: pull_request_target está prohibido"
  done < <(grep -nE '^[^#]*pull_request_target' "$f" || true)

  # 3. nada de secrets: inherit
  while IFS= read -r line; do
    err "$f:${line%%:*}: 'secrets: inherit' está prohibido"
  done < <(grep -nE '^[^#]*secrets["'"'"']?[[:space:]]*:[[:space:]]*["'"'"']?inherit' "$f" || true)

  # 4. permissions a nivel raíz (solo workflows), y nunca write-all
  if [[ "$f" == "$dir"/* ]] && ! grep -qE '^["'"'"']?permissions["'"'"']?[[:space:]]*:' "$f"; then
    err "$f: falta 'permissions:' a nivel raíz"
  fi
  while IFS= read -r line; do
    err "$f:${line%%:*}: 'permissions: write-all' está prohibido (usa un mapa con permisos concretos)"
  done < <(grep -nE '^[[:space:]]*["'"'"']?permissions["'"'"']?[[:space:]]*:[[:space:]]*["'"'"']?write-all["'"'"']?[[:space:]]*(#.*)?$' "$f" || true)
done

if ((errors > 0)); then
  printf '%d problema(s) en los workflows\n' "$errors" >&2
  exit 1
fi
printf 'workflows ok (%d archivo(s))\n' "${#files[@]}"
