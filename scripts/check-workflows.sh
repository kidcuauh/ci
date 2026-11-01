#!/usr/bin/env bash
# Guardia sin red sobre los workflows. Uso: check-workflows.sh [directorio]
# Falla (exit 1) con un mensaje por problema.
# Es una guardia de texto de mejor esfuerzo (grep), no un parser de YAML: frena
# accidentes y las formas comunes de `uses:`/`permissions:`. Los respaldos reales
# son zizmor en el job lint y los ajustes del repo (SHA obligatorio, allowlist
# sin patrones). Lo atesta el propio workflow del PR: no frena a un dueño
# comprometido, que puede editar la guardia.
set -euo pipefail

# Permisos que sí pueden ser write. Un elemento "scope" vale en todos los archivos;
# "archivo.yml:scope" solo en ese archivo (otra tarea puede necesitar, por ejemplo,
# "release.yml:contents"). Todo lo demás con write se rechaza.
WRITE_ALLOWED=("packages")

# Extrae el bloque `on:` de la raíz (número de línea:texto sin comentarios).
IFS= read -r -d '' AWK_ON <<'AWK' || true
/^["']?on["']?[[:space:]]*:/ { inon = 1; l = $0; sub(/^[^:]*:/, "", l); sub(/#.*/, "", l); print NR ":" l; next }
inon && /^[^[:space:]#-]/ { inon = 0 }
inon { l = $0; sub(/#.*/, "", l); print NR ":" l }
AWK

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

  # 2. nada de pull_request_target como disparador (clave bajo `on:`, lista o escalar);
  #    mencionarlo en un `if:` o un comentario no cuenta.
  on_block="$(awk "$AWK_ON" "$f")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    err "$f:${line%%:*}: pull_request_target está prohibido"
  done < <(grep -E 'pull_request_target' <<<"$on_block" || true)

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

  # 5. un workflow reutilizable lleva `permissions: {}` a nivel raíz
  if [[ "$f" == "$dir"/* ]] && grep -qE 'workflow_call' <<<"$on_block" &&
    ! grep -qE '^["'"'"']?permissions["'"'"']?[[:space:]]*:[[:space:]]*\{[[:space:]]*\}[[:space:]]*(#.*)?$' "$f"; then
    err "$f: un workflow con workflow_call debe llevar 'permissions: {}' a nivel raíz"
  fi

  # 6. ningún permiso write salvo los de WRITE_ALLOWED
  while IFS= read -r line; do
    n="${line%%:*}"
    # Todos los scopes write de la línea (un mapa en flujo puede traer varios).
    while IFS= read -r scope; do
      [[ -n "$scope" ]] || continue
      scope="$(printf '%s' "$scope" | sed -E 's/["'"'"']?[[:space:]]*:.*$//')"
      ok=0
      for a in ${WRITE_ALLOWED[@]+"${WRITE_ALLOWED[@]}"}; do
        if [[ "$a" == "$scope" || "$a" == "$(basename "$f"):$scope" ]]; then ok=1; fi
      done
      if ((!ok)); then err "$f:$n: permiso '$scope: write' no permitido (solo ${WRITE_ALLOWED[*]})"; fi
    done < <(printf '%s\n' "${line#*:}" | grep -oE '(actions|attestations|checks|contents|deployments|discussions|id-token|issues|models|packages|pages|pull-requests|repository-projects|security-events|statuses)["'"'"']?[[:space:]]*:[[:space:]]*["'"'"']?write' || true)
  done < <(grep -nE '^[^#]*(^|[[:space:]{,])["'"'"']?(actions|attestations|checks|contents|deployments|discussions|id-token|issues|models|packages|pages|pull-requests|repository-projects|security-events|statuses)["'"'"']?[[:space:]]*:[[:space:]]*["'"'"']?write["'"'"']?' "$f" || true)
done

if ((errors > 0)); then
  printf '%d problema(s) en los workflows\n' "$errors" >&2
  exit 1
fi
printf 'workflows ok (%d archivo(s))\n' "${#files[@]}"
