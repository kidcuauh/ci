#!/usr/bin/env bash
# Comprueba, solo con lectura (gh api + jq), que las protecciones de un repo
# (por defecto kidcuauh/ci) están como se espera. Necesita un token de admin:
# bypass_actors solo lo ve un admin.
# Exit: 0 todo bien, 1 falta algo (lista cada fallo), 2 falta una herramienta
# o el token no es admin.
# Uso: verify-protections.sh [--repo owner/nombre]
# No comprueba (manual): licencia MIT, que no haya GitHub Apps instaladas, ni que
# existan SECURITY.md y dependabot.yml.
# Los filtros de jq usan $variables de jq, no del shell.
# shellcheck disable=SC2016
set -uo pipefail

REPO="kidcuauh/ci"
while (($# > 0)); do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "falta el valor de --repo" >&2; exit 2; }
      REPO="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,9p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "argumento desconocido: $1" >&2
      exit 2
      ;;
  esac
  shift
done
OWNER="${REPO%%/*}"

# Expectativas: si cambia la lista de checks o de reglas, se actualizan aquí.
MAIN_RULE_TYPES='["deletion","non_fast_forward","pull_request","required_linear_history","required_signatures","required_status_checks"]'
TAGS_RULE_TYPES='["deletion","non_fast_forward","update"]'
EXPECTED_CHECKS='[{"context":"lint","integration_id":15368}]'

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "falta la herramienta: $tool" >&2; exit 2; }
done

FAILS=0
OUT=''
ok() { printf 'OK    %s\n' "$1"; }
bad() {
  printf 'FALLA %s\n' "$1"
  FAILS=$((FAILS + 1))
}

# fetch RUTA [ARGS_GH]: deja la respuesta en $OUT ('{}' si gh falla) y devuelve 1 si falla.
fetch() {
  local path="$1"
  shift
  if OUT="$(gh api "$@" "repos/$REPO${path:+/$path}" 2>/dev/null)"; then
    return 0
  fi
  OUT='{}'
  bad "no se pudo leer repos/$REPO${path:+/$path}"
  return 1
}

# fetch_list RUTA: igual, para listas paginadas; deja un solo arreglo en $OUT.
fetch_list() {
  local path="$1"
  if OUT="$(gh api --paginate "repos/$REPO/$path" 2>/dev/null | jq -s 'map(if type=="array" then . else [.] end) | add // []')" && [[ -n "$OUT" ]]; then
    return 0
  fi
  OUT='null'
  bad "no se pudo leer repos/$REPO/$path"
  return 1
}

# chk DESCRIPCIÓN JSON FILTRO [ARGS_JQ]: OK solo si jq -e sale 0 (true).
# Un error de jq o un null cuentan como FALLA.
chk() {
  local desc="$1" json="$2" filter="$3"
  shift 3
  if jq -e "$@" "$filter" <<<"$json" >/dev/null 2>&1; then
    ok "$desc"
  else
    bad "$desc"
  fi
}

# --- Repo y permisos del token ---
if ! repo_json="$(gh api "repos/$REPO" 2>/dev/null)"; then
  echo "ERROR: no se pudo leer repos/$REPO (¿gh sin sesión o repo inexistente?)" >&2
  exit 2
fi
if ! jq -e '.permissions.admin == true' <<<"$repo_json" >/dev/null 2>&1; then
  echo "ERROR: el token no es admin de $REPO; no se puede comprobar bypass_actors" >&2
  exit 2
fi

echo "Repo: $REPO"
chk "repo público" "$repo_json" '.private == false'
chk "rama por defecto = main" "$repo_json" '.default_branch == "main"'
chk "Issues apagado" "$repo_json" '.has_issues == false'
chk "Wiki apagada" "$repo_json" '.has_wiki == false'
chk "Projects apagado" "$repo_json" '.has_projects == false'
chk "Discussions apagado" "$repo_json" '.has_discussions == false'
chk "solo squash merge" "$repo_json" '.allow_squash_merge == true and .allow_merge_commit == false and .allow_rebase_merge == false'
chk "auto-merge apagado" "$repo_json" '.allow_auto_merge == false'
chk "borrar rama al fusionar" "$repo_json" '.delete_branch_on_merge == true'
chk "secret scanning activo" "$repo_json" '.security_and_analysis.secret_scanning.status == "enabled"'
chk "push protection activo" "$repo_json" '.security_and_analysis.secret_scanning_push_protection.status == "enabled"'
chk "Dependabot security updates activo" "$repo_json" '.security_and_analysis.dependabot_security_updates.status == "enabled"'

# --- Acceso ---
if fetch_list collaborators; then
  chk "colaboradores = solo el dueño" "$OUT" '(map(.login | ascii_downcase) | sort) == [($o | ascii_downcase)]' --arg o "$OWNER"
fi
if fetch_list invitations; then chk "0 invitaciones" "$OUT" 'length == 0'; fi
if fetch_list keys; then chk "0 deploy keys" "$OUT" 'length == 0'; fi
if fetch actions/secrets; then chk "0 secretos de Actions" "$OUT" '.total_count == 0'; fi
if fetch actions/variables; then chk "0 variables de Actions" "$OUT" '.total_count == 0'; fi

# --- Seguridad ---
if gh api "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1; then
  ok "Dependabot alerts activo"
else
  bad "Dependabot alerts activo"
fi
if fetch private-vulnerability-reporting; then chk "private vulnerability reporting activo" "$OUT" '.enabled == true'; fi
if fetch immutable-releases; then chk "releases inmutables activas" "$OUT" '.enabled == true'; fi

# --- Actions ---
if fetch actions/permissions; then
  chk "Actions: solo acciones seleccionadas" "$OUT" '.allowed_actions == "selected"'
  chk "Actions: SHA obligatorio" "$OUT" '.sha_pinning_required == true'
fi
if fetch actions/permissions/selected-actions; then
  chk "Actions: GitHub permitido, verificadas no, sin patrones" "$OUT" \
    '.github_owned_allowed == true and .verified_allowed == false and .patterns_allowed == []'
fi
if fetch actions/permissions/workflow; then
  chk "GITHUB_TOKEN de solo lectura" "$OUT" '.default_workflow_permissions == "read"'
  chk "Actions no aprueba PR" "$OUT" '.can_approve_pull_request_reviews == false'
fi
if fetch actions/permissions/fork-pr-contributor-approval; then
  chk "forks: aprobación para todos los externos" "$OUT" '.approval_policy == "all_external_contributors"'
fi

# --- Rulesets ---
RULESETS='[]'
if fetch_list rulesets; then RULESETS="$OUT"; fi

# ruleset_detail NOMBRE TIPO: deja el ruleset en $DETAIL; devuelve 1 si falta.
DETAIL='{}'
ruleset_detail() {
  local name="$1" target="$2" id
  id="$(jq -r --arg n "$name" --arg t "$target" '[.[] | select(.name == $n and .target == $t)][0].id // empty' <<<"$RULESETS" 2>/dev/null)"
  if [[ -z "$id" ]]; then
    bad "ruleset $name existe"
    return 1
  fi
  ok "ruleset $name existe (id $id)"
  fetch "rulesets/$id" || return 1
  DETAIL="$OUT"
  if ! jq -e 'has("bypass_actors")' <<<"$DETAIL" >/dev/null 2>&1; then
    echo "ERROR: el ruleset $name no trae bypass_actors: el token no es admin" >&2
    exit 2
  fi
  return 0
}

if ruleset_detail main branch; then
  chk "main: activo" "$DETAIL" '.enforcement == "active"'
  chk "main: objetivo rama" "$DETAIL" '.target == "branch"'
  chk "main: el usuario no puede saltarlo" "$DETAIL" '.current_user_can_bypass == "never"'
  chk "main: incluye la rama por defecto" "$DETAIL" '(.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH" or . == "refs/heads/main")'
  chk "main: sin exclusiones" "$DETAIL" '(.conditions.ref_name.exclude // []) | length == 0'
  chk "main: bypass_actors vacío" "$DETAIL" '.bypass_actors == []'
  for t in deletion non_fast_forward required_linear_history required_signatures; do
    chk "main: regla $t" "$DETAIL" '[.rules[]? | select(.type == $t)] | length == 1' --arg t "$t"
  done
  chk "main: sin reglas de más ni de menos" "$DETAIL" '([.rules[]?.type] | sort) == ($t | sort)' --argjson t "$MAIN_RULE_TYPES"
  chk "main: PR con 0 aprobaciones y solo squash" "$DETAIL" \
    '[.rules[]? | select(.type == "pull_request")][0].parameters | (.required_approving_review_count == 0 and .allowed_merge_methods == ["squash"])'
  chk "main: checks también al crear la rama" "$DETAIL" \
    '[.rules[]? | select(.type == "required_status_checks")][0].parameters.do_not_enforce_on_create == false'
  chk "main: rama al día (strict)" "$DETAIL" \
    '[.rules[]? | select(.type == "required_status_checks")][0].parameters.strict_required_status_checks_policy == true'
  chk "main: checks obligatorios (lint, app GitHub Actions)" "$DETAIL" \
    '[.rules[]? | select(.type == "required_status_checks")][0].parameters | ((.required_status_checks // []) | map({context, integration_id}) | sort_by(.context)) == ($e | sort_by(.context))' \
    --argjson e "$EXPECTED_CHECKS"
fi

if ruleset_detail tags-v tag; then
  chk "tags-v: activo" "$DETAIL" '.enforcement == "active"'
  chk "tags-v: objetivo tag" "$DETAIL" '.target == "tag"'
  chk "tags-v: el usuario no puede saltarlo" "$DETAIL" '.current_user_can_bypass == "never"'
  chk "tags-v: sin exclusiones" "$DETAIL" '(.conditions.ref_name.exclude // []) | length == 0'
  chk "tags-v: incluye refs/tags/v*" "$DETAIL" '(.conditions.ref_name.include // []) | any(. == "refs/tags/v*")'
  chk "tags-v: bypass_actors vacío" "$DETAIL" '.bypass_actors == []'
  for t in deletion non_fast_forward update; do
    chk "tags-v: regla $t" "$DETAIL" '[.rules[]? | select(.type == $t)] | length == 1' --arg t "$t"
  done
  chk "tags-v: sin reglas de más (p. ej. creation)" "$DETAIL" '([.rules[]?.type] | sort) == ($t | sort)' --argjson t "$TAGS_RULE_TYPES"
  chk "tags-v: update sin fetch-and-merge" "$DETAIL" \
    '([.rules[]? | select(.type == "update")][0].parameters.update_allows_fetch_and_merge // false) == false'
fi

if ((FAILS > 0)); then
  printf '\n%d comprobación(es) fallida(s)\n' "$FAILS"
  exit 1
fi
printf '\ntodo en orden\n'
