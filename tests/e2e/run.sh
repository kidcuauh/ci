#!/usr/bin/env bash
# Prueba e2e en kind: Flux endurecido como en la plataforma y un tenant que aplica
# examples/minimal (overlay dev) con el chart por digest y firma verificada.
# Uso: bash tests/e2e/run.sh   (necesita docker, kind, kubectl, flux y yq en el PATH)
# Entorno: E2E_REF (ref de git a probar; por defecto refs/heads/main) y
# E2E_REPO (owner/repo en GitHub; por defecto kidcuauh/ci).
# Si el digest del chart en examples/minimal es el de relleno (todo ceros), avisa y sale 0.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$root/tests/e2e"
ns=mi-equipo-dev
ref="${E2E_REF:-refs/heads/main}"
repo="${E2E_REPO:-kidcuauh/ci}"
cluster=e2e
node_image='kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed'
image=ghcr.io/mi-org/mi-app:sha-0123456789ab

log() { printf '\n== %s\n' "$*"; }
fail() {
  echo "::error::$*"
  exit 1
}

# Validación de entradas (llegan por entorno)
[[ "$ref" =~ ^refs/(heads|tags|pull)/[A-Za-z0-9._/-]+$ ]] || fail "E2E_REF inválido"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "E2E_REPO inválido"
# En un PR, Flux no resuelve el ref sintético refs/pull/N/merge ("object not found"):
# se prueba la cabeza del PR, refs/pull/N/head.
if [[ "$ref" =~ ^refs/pull/([0-9]+)/merge$ ]]; then ref="refs/pull/${BASH_REMATCH[1]}/head"; fi

chart_digest="$(yq '.spec.ref.digest' "$root/examples/minimal/infra/base/mi-app/ocirepository.yaml")"
if [[ "$chart_digest" =~ ^sha256:0+$ ]]; then
  # Nunca un verde vacío al publicar una release del chart.
  [[ "$ref" != refs/tags/chart-v* ]] || fail "digest de relleno en examples/minimal en una release del chart"
  echo "::notice::Aún no hay chart publicado (digest de relleno en examples/minimal): se omite la prueba e2e"
  exit 0
fi

diagnostico() {
  set +e
  echo "::group::Diagnóstico"
  flux get all -A
  kubectl get gitrepositories,ocirepositories,kustomizations,helmreleases -A -o yaml
  kubectl get events -A --sort-by=.lastTimestamp
  helm history -n "$ns" mi-app 2>/dev/null
  kubectl -n "$ns" get all,events,priorityclasses
  kubectl -n "$ns" describe pods
  kubectl -n flux-system logs deploy/source-controller --tail=200
  kubectl -n flux-system logs deploy/kustomize-controller --tail=200
  kubectl -n flux-system logs deploy/helm-controller --tail=200
  echo "::endgroup::"
}

work="$(mktemp -d)"
cleanup() {
  local rc=$?
  if ((rc != 0)); then diagnostico || true; fi
  rm -rf "$work"
  kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

cond() { # tipo nombre campo -> valor de la condición Ready (u otra) de un Kustomization
  kubectl -n "$ns" get kustomization "$2" \
    -o "jsonpath={.status.conditions[?(@.type==\"$1\")].$3}" 2>/dev/null || true
}

# espera_ks nombre campo regex: espera hasta 5 min a que la condición Ready tenga el campo con ese valor
espera_ks() {
  local end=$((SECONDS + 300)) v
  while ((SECONDS < end)); do
    v="$(cond Ready "$1" "$2")"
    if [[ "$v" =~ $3 ]]; then return 0; fi
    sleep 5
  done
  echo "Kustomization $1: $2='$(cond Ready "$1" "$2")' (se esperaba /$3/)" >&2
  return 1
}

log "Clúster kind"
kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
kind create cluster --name "$cluster" --image "$node_image" --wait 120s

log "Imagen de prueba"
docker build -t "$image" "$here/app"
kind load docker-image "$image" --name "$cluster"

log "Flux endurecido"
mkdir "$work/flux"
flux install --components=source-controller,kustomize-controller,helm-controller --export >"$work/flux/gotk-components.yaml"
cp "$here/flux/kustomization.yaml" "$work/flux/kustomization.yaml"
kubectl kustomize "$work/flux" >"$work/flux.yaml"
# args de cada controlador: flag esperado (+) o ausente (-)
args_de() {
  yq "select(.kind==\"Deployment\" and .metadata.name==\"$1\") | .spec.template.spec.containers[0].args[]" "$work/flux.yaml"
}
for c in kustomize-controller helm-controller; do
  a="$(args_de "$c")"
  for flag in --no-cross-namespace-refs=true --default-service-account=default; do
    grep -qxF -- "$flag" <<<"$a" || fail "falta $flag en $c"
  done
done
grep -qxF -- --no-remote-bases=true <<<"$(args_de kustomize-controller)" || fail "falta --no-remote-bases=true en kustomize-controller"
! grep -qxF -- --no-remote-bases=true <<<"$(args_de helm-controller)" || fail "--no-remote-bases en helm-controller"
for flag in --no-cross-namespace-refs=true --no-remote-bases=true --default-service-account=default; do
  ! grep -qxF -- "$flag" <<<"$(args_de source-controller)" || fail "$flag en source-controller"
done
kubectl apply --server-side -f "$work/flux.yaml"
kubectl -n flux-system wait deployment --all --for=condition=Available --timeout=300s

log "Plataforma del tenant"
kubectl apply -f "$here/platform.yaml"
role="$root/tests/fixtures/tenant-reconciler-role.yaml"
[[ -f "$role" ]] || fail "falta el fixture $role"
[[ "$(yq '.kind' "$role")" == ClusterRole && "$(yq '.metadata.name' "$role")" == tenant-reconciler ]] ||
  fail "el fixture debe ser el ClusterRole tenant-reconciler"
kubectl apply -f "$role"

log "Fuente y Kustomization del tenant"
cat >"$work/tenant.yaml" <<YAML
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: ci
  namespace: $ns
spec:
  interval: 1m
  url: https://github.com/$repo
  ref:
    name: $ref
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: mi-app
  namespace: $ns
spec:
  interval: 1m
  retryInterval: 30s
  timeout: 8m
  serviceAccountName: tenant-reconciler
  targetNamespace: $ns
  sourceRef:
    kind: GitRepository
    name: ci
  path: ./examples/minimal/infra/overlays/dev
  prune: true
  wait: true
  patches:
    # La imagen de la prueba se carga por tag en kind: sin digest.
    - target:
        kind: HelmRelease
        name: mi-app
      patch: |
        - op: add
          path: /spec/values/image/digest
          value: ""
YAML
kubectl apply -f "$work/tenant.yaml"

log "Positivo: examples/minimal aplicado con el chart por digest"
kubectl -n "$ns" wait gitrepository/ci --for=condition=Ready --timeout=180s
# Los crea otro controlador: primero esperar a que existan (kubectl wait no espera la creación).
kubectl -n "$ns" wait ocirepository/mi-app-chart --for=create --timeout=180s
kubectl -n "$ns" wait ocirepository/mi-app-chart --for=condition=SourceVerified=true --timeout=300s
kubectl -n "$ns" wait helmrelease/mi-app --for=create --timeout=180s
kubectl -n "$ns" wait helmrelease/mi-app --for=condition=Ready --timeout=480s
kubectl -n "$ns" wait deployment/mi-app --for=create --timeout=120s
kubectl -n "$ns" wait deployment/mi-app --for=condition=Available --timeout=180s
kubectl -n "$ns" wait kustomization/mi-app --for=condition=Ready --timeout=180s

log "Positivo: pods con securityContext restricted"
kubectl -n "$ns" get pods -o json >"$work/pods.json"
npods="$(yq -p json -oy '[.items[] | select(.metadata.name | test("^mi-app-"))] | length' "$work/pods.json")"
((npods >= 1)) || fail "no hay pods de mi-app"
# shellcheck disable=SC2016 # $s es una variable de yq, no del shell
bad="$(yq -p json -oy '.items[] | select(.metadata.name | test("^mi-app-")) | .spec as $s | (.spec.containers[], .spec.initContainers[]?) | select(
    ((.securityContext.runAsNonRoot // $s.securityContext.runAsNonRoot) != true) or
    ((.securityContext.runAsUser // $s.securityContext.runAsUser // 0) < 1) or
    (.securityContext.allowPrivilegeEscalation != false) or
    (.securityContext.readOnlyRootFilesystem != true) or
    (((.securityContext.capabilities.drop // []) | contains(["ALL"])) | not) or
    ((.securityContext.seccompProfile.type // $s.securityContext.seccompProfile.type) != "RuntimeDefault")
  ) | .name' "$work/pods.json")"
[[ -z "$bad" ]] || fail "contenedores sin securityContext restricted: $bad"
echo "pods verificados: $npods"

log "Negativo: un ClusterRole del tenant es rechazado"
kubectl apply -f - <<YAML
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: neg-clusterrole
  namespace: $ns
spec:
  interval: 1m
  timeout: 2m
  serviceAccountName: tenant-reconciler
  targetNamespace: $ns
  sourceRef:
    kind: GitRepository
    name: ci
  path: ./tests/e2e/negativos/clusterrole
  prune: true
  wait: true
YAML
espera_ks neg-clusterrole message 'clusterroles.*[Ff]orbidden|[Ff]orbidden.*clusterroles'
[[ "$(cond Ready neg-clusterrole status)" == False ]] || fail "neg-clusterrole debería estar en Ready False"
msg="$(cond Ready neg-clusterrole message)"
[[ "$msg" == *system:serviceaccount:$ns:tenant-reconciler* ]] || fail "el rechazo no es del tenant-reconciler: $msg"
echo "mensaje: $msg"
if kubectl get clusterrole mi-equipo-escape >/dev/null 2>&1; then
  fail "el ClusterRole del tenant existe"
fi

log "Negativo: una base remota de kustomize es rechazada"
kubectl apply -f - <<YAML
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: neg-base-remota
  namespace: $ns
spec:
  interval: 1m
  timeout: 2m
  serviceAccountName: tenant-reconciler
  targetNamespace: $ns
  sourceRef:
    kind: GitRepository
    name: ci
  path: ./tests/e2e/negativos/base-remota
  prune: true
  wait: true
YAML
espera_ks neg-base-remota reason '^BuildFailed$'
[[ "$(cond Ready neg-base-remota status)" == False ]] || fail "neg-base-remota debería estar en Ready False"
msg="$(cond Ready neg-base-remota message)"
# Con --no-remote-bases, kustomize-controller construye sobre un sistema de archivos
# seguro y rechaza lo que quede fuera de la raíz del artefacto ("fs-security-constraint").
# Cualquier otro error (red, git, ruta mal escrita) no prueba la bandera.
if [[ ! "$msg" =~ fs-security-constraint ]]; then
  fail "neg-base-remota no falló por --no-remote-bases: $msg"
fi
echo "mensaje: $msg"
for r in ocirepository/mi-app-chart-remota helmrelease/mi-app-remota; do
  if kubectl -n "$ns" get "$r" >/dev/null 2>&1; then fail "existe $r de la base remota"; fi
done

log "e2e correcto"
