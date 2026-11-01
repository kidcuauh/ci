#!/usr/bin/env bash
# Aplica a un repo (por defecto kidcuauh/ci) el estado de protecciones deseado.
# Por defecto solo muestra el plan; con --apply escribe. Es idempotente.
# Usa la sesión de gh: nunca recibe ni imprime un token. Discussions no se puede
# apagar por API: se apaga en la UI y verify solo lo comprueba.
# Uso: apply-protections.sh [--apply] [--repo owner/nombre]
set -euo pipefail

REPO="kidcuauh/ci"
APPLY=0
while (($# > 0)); do
  case "$1" in
    --apply) APPLY=1 ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "falta el valor de --repo" >&2; exit 2; }
      REPO="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,8p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "argumento desconocido: $1" >&2
      exit 2
      ;;
  esac
  shift
done

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "falta la herramienta: $tool" >&2; exit 2; }
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rulesets_dir="$root/.github/rulesets"
r="repos/$REPO"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# write MÉTODO RUTA [CUERPO_JSON]: imprime el plan, o escribe con --apply.
write() {
  local method="$1" path="$2" body="${3-}"
  if ((APPLY == 0)); then
    printf 'PLAN   %s %s\n' "$method" "$path"
    if [[ -n "$body" ]]; then
      jq . <<<"$body" | sed 's/^/         /'
    fi
    return 0
  fi
  printf 'APLICA %s %s\n' "$method" "$path"
  if [[ -n "$body" ]]; then
    gh api -X "$method" "$path" --silent --input - <<<"$body" || die "falló $method $path"
  else
    gh api -X "$method" "$path" --silent || die "falló $method $path"
  fi
}

# Los rulesets necesitan que exista la rama main: se comprueba antes de escribir nada.
if ! gh api "$r/branches/main" >/dev/null 2>&1; then
  if ((APPLY == 1)); then
    die "no existe la rama main en $REPO: el primer commit debe entrar antes de aplicar"
  fi
  echo "AVISO: no existe la rama main en $REPO; con --apply se abortaría sin escribir nada" >&2
fi

if ((APPLY == 0)); then
  echo "Modo plan: no se escribe nada. Usa --apply para aplicar."
fi
echo "Repo: $REPO"

# 1. Ajustes del repo
body="$(jq -nc '{
  description: "Workflows reutilizables de CI, sin secretos",
  has_issues: false, has_wiki: false, has_projects: false,
  allow_squash_merge: true, allow_merge_commit: false, allow_rebase_merge: false,
  allow_auto_merge: false, delete_branch_on_merge: true,
  squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "PR_BODY",
  security_and_analysis: {
    secret_scanning: {status: "enabled"},
    secret_scanning_push_protection: {status: "enabled"}
  }
}')"
write PATCH "$r" "$body"

# 2. Alertas y reporte privado de Dependabot
write PUT "$r/vulnerability-alerts"
write PUT "$r/automated-security-fixes"
write PUT "$r/private-vulnerability-reporting"

# 3. Actions
write PUT "$r/actions/permissions" \
  '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}'
write PUT "$r/actions/permissions/selected-actions" \
  '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":[]}'
write PUT "$r/actions/permissions/workflow" \
  '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
write PUT "$r/actions/permissions/fork-pr-contributor-approval" \
  '{"approval_policy":"all_external_contributors"}'

# 4. Releases inmutables
write PUT "$r/immutable-releases"

# 5. Rulesets
if ! existing="$(gh api --paginate "$r/rulesets" 2>/dev/null | jq -s 'map(if type=="array" then . else [.] end) | add // []')"; then
  if ((APPLY == 1)); then
    die "no se pudo listar los rulesets de $REPO"
  fi
  echo "AVISO: no se pudo listar los rulesets; el plan supone que no existen" >&2
  existing='[]'
fi

for f in main tags-v; do
  file="$rulesets_dir/$f.json"
  [[ -f "$file" ]] || die "falta $file"
  jq -e . "$file" >/dev/null || die "$file no es JSON válido"
  name="$(jq -r .name "$file")"
  body="$(jq -c . "$file")"
  id="$(jq -r --arg n "$name" '[.[] | select(.name == $n)][0].id // empty' <<<"$existing")"
  if [[ -n "$id" ]]; then
    write PUT "$r/rulesets/$id" "$body"
  else
    write POST "$r/rulesets" "$body"
  fi
done

echo "Listo. Comprueba el resultado con scripts/verify-protections.sh"
