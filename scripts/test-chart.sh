#!/usr/bin/env bash
# Pruebas del chart app, sin cluster. Uso: test-chart.sh (sin argumentos). Requiere helm y yq.
# Sale 0 si todo pasa y 1 si algo falla. UPDATE_GOLDEN=1 regenera el golden de selectores.
#
# Qué comprueba:
#  - tests/chart/ok/*.yaml: helm lint y helm template pasan (valores = base.yaml + el caso, o solo
#    el caso con "# base: ninguna") y
#    cada línea "# afirma: <expresión yq>" da true sobre los documentos renderizados.
#  - tests/chart/fail/*.yaml: helm template falla y el error contiene el texto de
#    "# espera: <texto>". "# release: <nombre>" cambia el nombre del release y "# base: ninguna"
#    quita el base. Los tokens
#    @@AWS@@, @@GITHUB@@, @@PEM@@, @@JWT@@, @@STRIPE@@ y @@URL@@ se arman aquí, concatenando, para que
#    ningún literal con forma de credencial viva en el repo.
#  - examples/: cada overlay (values de la HelmRelease base + el patch) renderiza.
#  - Todo kind renderizado tiene create en el Role de tests/fixtures; nunca salen Secret,
#    ConfigMap, PVC, NetworkPolicy, Role, RoleBinding ni HTTPRoute; los pods cumplen
#    Pod Security restricted.
#  - Los selectores no cambian respecto al golden (tests/chart/golden/).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$root/charts/app"
tc="$root/tests/chart"
role="$root/tests/fixtures/tenant-reconciler-role.yaml"

for tool in helm yq; do
  command -v "$tool" >/dev/null || {
    echo "falta $tool en el PATH" >&2
    exit 2
  }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
checks=0

fail() {
  printf 'FALLA %s\n' "$*" >&2
  failures=$((failures + 1))
}

# Credenciales de mentira, armadas en tiempo de ejecución.
tok_aws="AKI""AIOSFODNN7EXAMPLE"
tok_github="gh""p_0123456789abcdefghijklmnopqrstuvwxyz"
tok_pem="-----BEGIN ""RSA PRIVATE KEY-----"
tok_jwt="ey""JhbGciOiJIUzI1NiJ9.ey""JzdWIiOiJ4In0.firma"
tok_stripe="sk_""live_0123456789abcdef"
tok_url="postgres://usuario:clave""@db.example.com:5432/mi"

materialize() { # origen destino
  sed -e "s|@@AWS@@|$tok_aws|g" -e "s|@@GITHUB@@|$tok_github|g" -e "s|@@PEM@@|$tok_pem|g" \
    -e "s|@@JWT@@|$tok_jwt|g" -e "s|@@STRIPE@@|$tok_stripe|g" -e "s|@@URL@@|$tok_url|g" "$1" >"$2"
}

header() { # archivo clave -> primer valor de "# clave: valor"
  sed -n "s/^# $2: //p" "$1" | head -n 1
}

# kind (apiVersion + kind) -> grupo/recurso del Role
resource_of() { # apiVersion kind
  local group=""
  [[ "$1" == */* ]] && group="${1%%/*}"
  case "$2" in
    Deployment) echo "apps deployments" ;;
    Service) echo " services" ;;
    ServiceAccount) echo " serviceaccounts" ;;
    Ingress) echo "networking.k8s.io ingresses" ;;
    PodDisruptionBudget) echo "policy poddisruptionbudgets" ;;
    CronJob) echo "batch cronjobs" ;;
    Job) echo "batch jobs" ;;
    InfisicalStaticSecret) echo "secrets.infisical.com infisicalstaticsecrets" ;;
    *) echo "$group ?" ;;
  esac
}

check_kinds() { # nombre renderizado
  local name="$1" file="$2" av kind res group resource
  while read -r av kind; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      Secret | ConfigMap | PersistentVolumeClaim | NetworkPolicy | Role | RoleBinding | ClusterRole | ClusterRoleBinding | HTTPRoute)
        fail "$name: no debe renderizar $kind"
        continue
        ;;
    esac
    res="$(resource_of "$av" "$kind")"
    group="${res%% *}"
    resource="${res#* }"
    if [[ "$resource" == "?" ]]; then
      fail "$name: kind sin mapeo al Role: $av $kind"
      continue
    fi
    if ! G="$group" R="$resource" yq -e '[.rules[] | select((.apiGroups | contains([strenv(G)])) and (.resources | contains([strenv(R)])) and (.verbs | contains(["create"])))] | length > 0' "$role" >/dev/null; then
      fail "$name: $kind ($group/$resource) no tiene create en el Role de tenant-reconciler"
    fi
  done < <(yq ea 'select(.kind != null) | .apiVersion + " " + .kind' "$file" | sort -u)
}

# Pod Security restricted sobre todo pod renderizado: containers e initContainers, volúmenes
# de una lista permitida, sin hostPort ni sysctls.
# shellcheck disable=SC2016
PSS='.[] | select(.kind == "Deployment" or .kind == "CronJob" or .kind == "Job")
  | (.spec.template.spec // .spec.jobTemplate.spec.template.spec) as $p
  | {"n": (.kind + "/" + .metadata.name), "ok": (
      (($p.hostNetwork // false) == false) and (($p.hostPID // false) == false) and (($p.hostIPC // false) == false)
      and ($p.securityContext.runAsNonRoot == true)
      and ($p.securityContext.runAsUser > 0)
      and ($p.securityContext.seccompProfile.type == "RuntimeDefault")
      and ($p.automountServiceAccountToken == false)
      and ((($p.securityContext.sysctls // []) | length) == 0)
      and ((($p.securityContext.supplementalGroups // []) | length) == 0)
      and (([($p.volumes // [])[] | select(
            (keys - ["name", "configMap", "secret", "emptyDir", "persistentVolumeClaim", "projected", "downwardAPI"] | length) > 0
          )] | length) == 0)
      and (([(($p.containers // []) + ($p.initContainers // []) + ($p.ephemeralContainers // []))[] | select(
            .securityContext.allowPrivilegeEscalation != false
            or .securityContext.readOnlyRootFilesystem != true
            or .securityContext.runAsNonRoot != true
            or .securityContext.privileged == true
            or (((.securityContext.capabilities.drop // []) | contains(["ALL"])) | not)
            or (((.securityContext.capabilities.add // []) | length) > 0)
            or (([(.ports // [])[] | select(has("hostPort"))] | length) > 0)
          )] | length) == 0)
    )}
  | select(.ok == false) | .n'

# Los selectores de Deployments y Services deben ser subconjunto de los labels del pod.
# shellcheck disable=SC2016
SELCHK='([.[] | select(.kind == "Deployment") | .spec.selector.matchLabels as $m | .spec.template.metadata.labels as $l
      | select(([$m | to_entries[] | select($l[.key] != .value)] | length) > 0) | "Deployment/" + .metadata.name])
  + ([.[] | select(.kind == "Service") | .spec.selector as $m
      | select(([$m | to_entries[] | select(. as $e | ([env(PODS) | .[] | select(.[$e.key] == $e.value)] | length) == 0)] | length) > 0) | "Service/" + .metadata.name])'

check_pss() { # nombre renderizado
  local bad
  bad="$(yq ea '[.]' "$2" | yq "$PSS")"
  [[ -z "$bad" ]] || fail "$1: incumple Pod Security restricted: $(echo "$bad" | tr '\n' ' ')"
}

check_selectors() { # nombre renderizado
  local bad
  yq ea '[.]' "$2" >"$work/sel-lista.yaml"
  bad="$(yq '[.[] | select(.kind == "Deployment") | .spec.template.metadata.labels]' "$work/sel-lista.yaml" -o json -I0)"
  bad="$(PODS="$bad" yq "$SELCHK | .[]" "$work/sel-lista.yaml")"
  [[ -z "$bad" ]] || fail "$1: el selector no cuadra con los labels del pod: $(echo "$bad" | tr '\n' ' ')"
}

# ---------------------------------------------------------------- estructura del chart
checks=$((checks + 1))
if grep -rEq '^kind:[[:space:]]*(Secret|ConfigMap|PersistentVolumeClaim|NetworkPolicy|Role|RoleBinding|ClusterRole|ClusterRoleBinding|HTTPRoute)\b' "$chart/templates"; then
  fail "charts/app/templates no debe contener plantillas de Secret, ConfigMap, PVC, NetworkPolicy, RBAC ni HTTPRoute"
fi
checks=$((checks + 1))
sin_cierre="$(yq -p json -o json '[.. | select(tag == "!!map" and .type == "object" and (has("additionalProperties") | not))] | length' "$chart/values.schema.json")"
[[ "$sin_cierre" == "0" ]] || fail "values.schema.json: hay $sin_cierre objetos sin additionalProperties: false"
checks=$((checks + 1))
[[ "$(yq '.name' "$chart/Chart.yaml")" == "app" ]] || fail "Chart.yaml: el nombre debe ser app"
checks=$((checks + 1))
[[ "$(yq '.maintainers' "$chart/Chart.yaml")" == "null" ]] || fail "Chart.yaml: sin maintainers"

# ---------------------------------------------------------------- autoprueba de las guardias
# Las guardias de kinds y de Pod Security deben detectar un render alterado a propósito.
helm template mi-app "$chart" -f "$tc/base.yaml" >"$work/sano.out"
for mut in 's/readOnlyRootFilesystem: true/readOnlyRootFilesystem: false/' \
  's/runAsNonRoot: true/runAsNonRoot: false/' \
  's/- ALL/- NET_ADMIN/' \
  's/RuntimeDefault/Unconfined/' \
  's/automountServiceAccountToken: false/automountServiceAccountToken: true/' \
  's/^kind: Service$/kind: NetworkPolicy/' \
  's/^\( *\)- containerPort: /\1- hostPort: 80\
\1  containerPort: /'; do
  checks=$((checks + 1))
  sed "$mut" "$work/sano.out" >"$work/mutado.out"
  nfail_before=$failures
  case "$mut" in
    *NetworkPolicy*) check_kinds autoprueba "$work/mutado.out" 2>/dev/null ;;
    *) check_pss autoprueba "$work/mutado.out" 2>/dev/null ;;
  esac
  if ((failures == nfail_before)); then
    fail "autoprueba: la guardia no detectó la mutación $mut"
  else
    failures=$nfail_before
  fi
done

# ---------------------------------------------------------------- casos ok
shopt -s nullglob
nok=0
for f in "$tc"/ok/*.yaml; do
  name="ok/$(basename "$f" .yaml)"
  nok=$((nok + 1))
  ns="$(header "$f" namespace)"
  ns="${ns:-default}"
  out="$work/$(basename "$f" .yaml).out"
  basef=("-f" "$tc/base.yaml")
  [[ "$(header "$f" base)" != "ninguna" ]] || basef=()
  if ! helm lint "$chart" ${basef[@]+"${basef[@]}"} -f "$f" >"$work/lint.out" 2>&1; then
    fail "$name: helm lint falla: $(tail -n 5 "$work/lint.out" | tr '\n' ' ')"
    continue
  fi
  if ! helm template mi-app "$chart" -n "$ns" ${basef[@]+"${basef[@]}"} -f "$f" >"$out" 2>"$work/err.out"; then
    fail "$name: helm template falla: $(head -n 5 "$work/err.out" | tr '\n' ' ')"
    continue
  fi
  # Las afirmaciones corren sobre una lista con todos los documentos: en yq ea, "and" mezcla
  # documentos distintos.
  yq ea '[.]' "$out" >"$work/lista.yaml"
  while IFS= read -r expr; do
    [[ -n "$expr" ]] || continue
    checks=$((checks + 1))
    res="$(yq "$expr" "$work/lista.yaml" 2>&1 || true)"
    if [[ -z "$res" ]] || [[ -n "$(printf '%s\n' "$res" | grep -v '^true$' || true)" ]]; then
      fail "$name: la afirmación no se cumple: $expr (resultado: $(echo "$res" | tr '\n' ' '))"
    fi
  done < <(sed -n 's/^# afirma: //p' "$f")
  checks=$((checks + 2))
  check_kinds "$name" "$out"
  check_pss "$name" "$out"
  check_selectors "$name" "$out"
done

# ---------------------------------------------------------------- casos fail
nfail=0
for f in "$tc"/fail/*.yaml; do
  name="fail/$(basename "$f" .yaml)"
  nfail=$((nfail + 1))
  checks=$((checks + 1))
  esperado="$(header "$f" espera)"
  rel="$(header "$f" release)"
  rel="${rel:-mi-app}"
  if [[ -z "$esperado" ]]; then
    fail "$name: falta la línea '# espera: <texto>'"
    continue
  fi
  materialize "$f" "$work/caso.yaml"
  basef=("-f" "$tc/base.yaml")
  [[ "$(header "$f" base)" != "ninguna" ]] || basef=()
  if helm template "$rel" "$chart" ${basef[@]+"${basef[@]}"} -f "$work/caso.yaml" >"$work/fail.out" 2>"$work/fail.err"; then
    fail "$name: helm template debía fallar y pasó"
  elif ! grep -qF -- "$esperado" "$work/fail.err"; then
    fail "$name: el error no contiene '$esperado': $(head -n 6 "$work/fail.err" | tr '\n' ' ')"
  fi
done

# ---------------------------------------------------------------- ejemplos
nex=0
for ex in "$root"/examples/*/; do
  base="$ex/infra/base"
  for ov in "$ex"/infra/overlays/*/; do
    for patch in "$ov"/*.patch.yaml; do
      app="$(basename "$patch" .patch.yaml)"
      name="examples/$(basename "$ex")/$(basename "$ov")/$app"
      nex=$((nex + 1))
      vals="$work/ex-values.yaml"
      yq ea 'select(fileIndex == 0).spec.values * select(fileIndex == 1).spec.values' "$base/$app/helmrelease.yaml" "$patch" >"$vals"
      out="$work/ex.out"
      checks=$((checks + 3))
      if ! helm lint "$chart" -f "$vals" >"$work/lint.out" 2>&1; then
        fail "$name: helm lint falla: $(tail -n 5 "$work/lint.out" | tr '\n' ' ')"
        continue
      fi
      if ! helm template "$app" "$chart" -n ejemplo -f "$vals" >"$out" 2>"$work/err.out"; then
        fail "$name: helm template falla: $(head -n 5 "$work/err.out" | tr '\n' ' ')"
        continue
      fi
      check_kinds "$name" "$out"
      check_pss "$name" "$out"
      check_selectors "$name" "$out"
    done
  done
done
[[ "$nex" -gt 0 ]] || fail "no se encontraron ejemplos en examples/"

# ---------------------------------------------------------------- golden de selectores
# shellcheck disable=SC2016
SEL='([.[] | select(.kind == "Deployment" or .kind == "PodDisruptionBudget")
    | {"kind": .kind, "name": .metadata.name, "selector": .spec.selector.matchLabels}]
  + [.[] | select(.kind == "Service") | {"kind": .kind, "name": .metadata.name, "selector": .spec.selector}])
  | sort_by(.kind + "/" + .name)'
checks=$((checks + 1))
if ! helm template golden "$chart" -f "$tc/golden/values.yaml" >"$work/golden.out" 2>"$work/err.out"; then
  fail "golden: helm template falla: $(head -n 5 "$work/err.out" | tr '\n' ' ')"
else
  yq ea '[.]' "$work/golden.out" | yq "$SEL" >"$work/selectors.yaml"
  check_kinds golden "$work/golden.out"
  check_pss golden "$work/golden.out"
  check_selectors golden "$work/golden.out"
  if [[ "${UPDATE_GOLDEN:-}" == "1" ]]; then
    cp "$work/selectors.yaml" "$tc/golden/selectors.yaml"
    echo "golden actualizado: tests/chart/golden/selectors.yaml"
  elif ! diff -u "$tc/golden/selectors.yaml" "$work/selectors.yaml" >"$work/golden.diff"; then
    fail "golden: los selectores cambiaron (el spec.selector nunca debe cambiar):
$(cat "$work/golden.diff")"
  fi
fi

if ((failures > 0)); then
  printf '%d falla(s) en %d comprobaciones\n' "$failures" "$checks" >&2
  exit 1
fi
printf 'chart app: %d casos ok, %d casos fail, %d ejemplos, %d comprobaciones: todo en verde\n' "$nok" "$nfail" "$nex" "$checks"
