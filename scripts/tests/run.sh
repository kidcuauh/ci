#!/usr/bin/env bash
# Pruebas sin red de verify-protections, apply-protections y check-workflows.
# Usan el gh falso de scripts/tests/fake-gh y los fixtures de scripts/tests/fixtures.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Los fixtures de los rulesets no son copias congeladas: se generan aquí desde
# .github/rulesets/*.json (lo que apply escribe), para que verify los compruebe.
good="$tmp/good"
cp -R "$here/fixtures/good" "$good"
jq '. + {id: 101, source_type: "Repository", current_user_can_bypass: "never"}' "$root/.github/rulesets/main.json" >"$good/rulesets__101.json"
jq '. + {id: 102, source_type: "Repository", current_user_can_bypass: "never"}' "$root/.github/rulesets/tags-v.json" >"$good/rulesets__102.json"

# Copia del gh falso con permiso de ejecución: un commit creado por la API de
# GitHub no conserva el bit +x.
mkdir -p "$tmp/fake-bin"
cp "$here/fake-gh/gh" "$tmp/fake-bin/gh"
chmod +x "$tmp/fake-bin/gh"
export PATH="$tmp/fake-bin:$PATH"
PASS=0
FAILED=0

result() { # nombre ok(0/1) [detalle]
  if (($2 == 0)); then
    printf 'ok    %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %s%s\n' "$1" "${3:+ ($3)}"
    FAILED=$((FAILED + 1))
  fi
}

# run_verify DIR -> exit code de verify-protections.sh con ese fixture
run_verify() {
  FAKE_GH_DIR="$1" FAKE_GH_LOG=/dev/null bash "$root/scripts/verify-protections.sh" >"$tmp/verify.out" 2>&1
}

expect_exit() { # nombre esperado obtenido
  if [[ "$2" == "nz" ]]; then
    [[ "$3" -ne 0 ]]
  else
    [[ "$3" -eq "$2" ]]
  fi
  result "$1" $? "exit $3, esperado $2"
}

# (a) fixtures buenos
run_verify "$good"
expect_exit "verify: estado correcto sale 0" 0 $?
grep -q '^FALLA' "$tmp/verify.out"
result "verify: estado correcto sin líneas FALLA" $((! $?))

# (b) casos malos: copia de good mutada
bad_case() { # nombre esperado archivo filtro-jq|DELETE
  local name="$1" expect="$2" file="$3" filter="$4" d code
  d="$tmp/case-$RANDOM-$RANDOM"
  cp -R "$good" "$d"
  if [[ "$filter" == DELETE ]]; then
    rm -f "$d/$file"
  else
    jq "$filter" "$d/$file" >"$d/$file.new" && mv "$d/$file.new" "$d/$file"
  fi
  run_verify "$d"
  code=$?
  expect_exit "verify: $name" "$expect" "$code"
}

bad_case "default branch distinta de main" 1 repo.json '.default_branch = "trunk"'
bad_case "tags-v con exclusión" 1 rulesets__102.json '.conditions.ref_name.exclude = ["refs/tags/v*"]'
bad_case "tags-v con objetivo rama" 1 rulesets__102.json '.target = "branch"'
bad_case "main con objetivo tag" 1 rulesets__101.json '.target = "tag"'
bad_case "main con do_not_enforce_on_create" 1 rulesets__101.json '(.rules[] | select(.type == "required_status_checks") | .parameters.do_not_enforce_on_create) = true'
bad_case "main saltable por el usuario" 1 rulesets__101.json '.current_user_can_bypass = "always"'
bad_case "bypass no vacío" 1 rulesets__101.json '.bypass_actors = [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
bad_case "clave bypass_actors ausente (token sin admin) sale 2" 2 rulesets__101.json 'del(.bypass_actors)'
bad_case "token sin admin sale 2" 2 repo.json '.permissions.admin = false'
bad_case "ruleset main disabled" 1 rulesets__101.json '.enforcement = "disabled"'
bad_case "falta required_signatures" 1 rulesets__101.json '.rules |= map(select(.type != "required_signatures"))'
bad_case "allowed_merge_methods con merge" 1 rulesets__101.json '(.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods) = ["merge","squash"]'
bad_case "check lint ausente" 1 rulesets__101.json '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = []'
bad_case "check resultado ausente" 1 rulesets__101.json '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "resultado"))'
bad_case "check chart ausente" 1 rulesets__101.json '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "chart"))'
bad_case "check contenido ausente" 1 rulesets__101.json '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "contenido"))'
bad_case "tags-v sin chart-v*" 1 rulesets__102.json '.conditions.ref_name.include = ["refs/tags/v*"]'
bad_case "tags-v con un patrón de más" 1 rulesets__102.json '.conditions.ref_name.include += ["refs/tags/*"]'
bad_case "check lint con otra app" 1 rulesets__101.json '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].integration_id) = 1'
bad_case "rama no al día (strict false)" 1 rulesets__101.json '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = false'
bad_case "ruleset tags-v ausente" 1 rulesets.json 'map(select(.name != "tags-v"))'
bad_case "tags-v con bypass" 1 rulesets__102.json '.bypass_actors = [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
bad_case "tags-v con regla creation" 1 rulesets__102.json '.rules += [{"type":"creation"}]'
bad_case "tags-v update con fetch-and-merge" 1 rulesets__102.json '(.rules[] | select(.type == "update") | .parameters.update_allows_fetch_and_merge) = true'
bad_case "tags-v update sin parameters (GitHub omite el defecto) sale 0" 0 rulesets__102.json '(.rules[] | select(.type == "update")) |= del(.parameters)'
bad_case "releases inmutables apagadas" 1 immutable-releases.json '.enabled = false'
bad_case "GITHUB_TOKEN en write" 1 actions__permissions__workflow.json '.default_workflow_permissions = "write"'
bad_case "push protection apagado" 1 repo.json '.security_and_analysis.secret_scanning_push_protection.status = "disabled"'
bad_case "colaborador extra" 1 collaborators.json '. + [{"login":"intruso"}]'
bad_case "allowed_actions all" 1 actions__permissions.json '.allowed_actions = "all"'
bad_case "approval_policy distinto" 1 actions__permissions__fork-pr-contributor-approval.json '.approval_policy = "first_time_contributors"'
bad_case "Dependabot alerts apagado (404)" 1 vulnerability-alerts.json DELETE
bad_case "lectura que falla cuenta como FALLA" 1 immutable-releases.json DELETE
bad_case "un secreto de Actions" 1 actions__secrets.json '.total_count = 1'

# (c) apply-protections
run_apply() { # dir log args...
  local d="$1" log="$2"
  shift 2
  : >"$log"
  FAKE_GH_DIR="$d" FAKE_GH_LOG="$log" bash "$root/scripts/apply-protections.sh" "$@" >"$tmp/apply.out" 2>&1
}

log="$tmp/apply.log"
run_apply "$good" "$log"
code=$?
expect_exit "apply: sin --apply sale 0" 0 $code
rc=0
if [[ -s "$log" ]]; then rc=1; fi
result "apply: sin --apply no registra escrituras" "$rc"
grep -q '^PLAN   PATCH' "$tmp/apply.out"
result "apply: sin --apply imprime el plan" $?

run_apply "$good" "$log" --apply
code=$?
expect_exit "apply: --apply sale 0" 0 $code
r=repos/kidcuauh/ci
expected="PATCH $r
PUT $r/vulnerability-alerts
PUT $r/automated-security-fixes
PUT $r/private-vulnerability-reporting
PUT $r/actions/permissions
PUT $r/actions/permissions/selected-actions
PUT $r/actions/permissions/workflow
PUT $r/actions/permissions/fork-pr-contributor-approval
PUT $r/immutable-releases
PUT $r/rulesets/101
PUT $r/rulesets/102"
got="$(awk '{print $1, $2}' "$log")"
rc=0
if [[ "$got" != "$expected" ]]; then rc=1; fi
detalle="$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") | head -5 | tr '\n' ' ')"
result "apply: --apply escribe lo esperado y en orden (rulesets al final, PUT)" "$rc" "$detalle"
grep -q '"allowed_actions":"selected"' "$log" && grep -q '"sha_pinning_required":true' "$log" && grep -q '"required_signatures"' "$log"
result "apply: los cuerpos llevan lo esperado" $?

# idempotencia: segunda corrida igual
first="$(cat "$log")"
run_apply "$good" "$log" --apply
[[ "$(cat "$log")" == "$first" ]]
result "apply: idempotente (misma secuencia al repetir)" $?

# sin rulesets existentes -> POST
d="$tmp/norulesets"
cp -R "$good" "$d"
echo '[]' >"$d/rulesets.json"
run_apply "$d" "$log" --apply
tail -n 2 "$log" | awk '{print $1, $2}' | tr '\n' '|' | grep -qF "POST $r/rulesets|POST $r/rulesets|"
result "apply: sin rulesets existentes hace POST de los dos" $?

# rama main ausente -> aborta antes de crear rulesets
d="$tmp/nomain"
cp -R "$good" "$d"
rm "$d/branches__main.json"
run_apply "$d" "$log" --apply
code=$?
expect_exit "apply: sin rama main sale distinto de 0" nz $code
[[ ! -s "$log" ]]
result "apply: sin rama main no escribe nada" $?

# (d) check-workflows
bash "$root/scripts/check-workflows.sh" >/dev/null 2>&1
expect_exit "check-workflows: pasa sobre .github/workflows real" 0 $?
bash "$root/scripts/check-workflows.sh" "$here/fixtures/workflows/bueno" >/dev/null 2>&1
expect_exit "check-workflows: fixture bueno pasa" 0 $?
for c in tercero tag sha-corto pull-request-target secrets-inherit sin-permissions permissions-write uses-flow uses-comillas uses-espacio secrets-inherit-comillas \
  prt-lista prt-escalar call-permissions-no-vacios write-contents write-id-token write-attestations-flow \
  prt-lista-sin-indent call-lista-sin-indent write-flow-dos \
  self-main-otro-archivo self-main-otra-rama self-main-otro-repo self-main-sha \
  self-main-ci-evil self-main-main-x uses-comentario; do
  bash "$root/scripts/check-workflows.sh" "$here/fixtures/workflows/$c" >/dev/null 2>&1
  expect_exit "check-workflows: falla con $c" 1 $?
done

for c in prt-solo-en-if call-ok write-packages-ok release-chart-ok self-main-ok self-main-comentario-ok; do
  bash "$root/scripts/check-workflows.sh" "$here/fixtures/workflows/$c" >/dev/null 2>&1
  expect_exit "check-workflows: fixture $c pasa" 0 $?
done

# directorio sin workflows: falla con mensaje claro, sin variable sin definir
bash "$root/scripts/check-workflows.sh" "$tmp/no-existe" >"$tmp/cw.out" 2>&1
expect_exit "check-workflows: sin workflows falla" 1 $?
! grep -q 'unbound' "$tmp/cw.out"
result "check-workflows: sin workflows no revienta con unbound" $?

# (e) cleanup-select
# shellcheck source=/dev/null
source "$here/cleanup-select-tests.sh"

printf '\n%d ok, %d fallidas\n' "$PASS" "$FAILED"
((FAILED == 0))
