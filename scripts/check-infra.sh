#!/usr/bin/env bash
# Verificador del infra/ de un repo que consume el chart "app". Sin cluster ni secretos.
# Uso: check-infra.sh [--chart-dir DIR] [--kubernetes-version X.Y.Z] [--schemas DIR] <raíz-del-repo>
# Documentación: docs/check-infra.md.
#   --chart-dir DIR            usa ese chart local en vez de bajarlo por digest del OCIRepository
#   --kubernetes-version X.Y.Z versión de los esquemas de Kubernetes (por defecto 1.36.5)
#   --schemas DIR              esquemas de los CRD (por defecto schemas/ de este repo)
# Junta todos los errores ("ERROR <archivo>: <qué cambiar>") y sale 1 si hubo alguno, 0 si no,
# 2 si falta una herramienta o los argumentos son inválidos. No ejecuta nada del repo que se
# revisa: lo estático va antes de `flux build`, y si lo estático falla no se construye nada.
# Requiere helm, flux, kubeconform, gitleaks y yq (mikefarah v4); scripts/install-tools.sh los instala.
set -euo pipefail

CI_REPO_URL_PREFIX="oci://ghcr.io/kidcuauh/charts/"
OIDC_ISSUER='^https://token\.actions\.githubusercontent\.com$'
OIDC_SUBJECT='^https://github\.com/kidcuauh/ci/\.github/workflows/release-chart\.yml@refs/tags/chart-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
RE_DNS='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

# Kinds que un tenant nunca aplica (los demás límites son del Role de la plataforma).
FORBIDDEN_KINDS="Role RoleBinding ClusterRole ClusterRoleBinding NetworkPolicy ResourceQuota LimitRange Endpoints EndpointSlice DaemonSet Kustomization GitRepository Bucket HelmRepository HelmChart InfisicalAuth InfisicalConnection InfisicalSecret InfisicalPushSecret InfisicalDynamicSecret DNSEndpoint"
# Kinds de alcance cluster conocidos (la lista es de mejor esfuerzo; el Role lo impone de verdad).
CLUSTER_KINDS="Namespace Node PersistentVolume StorageClass CustomResourceDefinition PriorityClass ValidatingAdmissionPolicy ValidatingAdmissionPolicyBinding MutatingAdmissionPolicy MutatingAdmissionPolicyBinding ValidatingWebhookConfiguration MutatingWebhookConfiguration IngressClass RuntimeClass APIService CSIDriver CSINode VolumeAttachment CertificateSigningRequest ClusterTrustBundle ClusterIssuer ClusterPolicy ClusterSecretStore ClusterGenerator ClusterImageCatalog GatewayClass FlowSchema PriorityLevelConfiguration ServiceCIDR IPAddress DeviceClass ResourceSlice VolumeAttributesClass StorageVersionMigration SubjectAccessReview TokenReview"
FORBIDDEN_GROUPS="traefik.io traefik.containo.us gateway.networking.k8s.io monitoring.coreos.com rbac.authorization.k8s.io"
# Campos de kustomization permitidos (lista cerrada y sensible a mayúsculas: kustomize decodifica
# sin distinguirlas, así que cualquier otra escritura, o campo, se rechaza). Los campos que
# ejecutan o traen contenido de fuera de infra/ (helmCharts, generators, transformers,
# validators, openapi, secretGenerator, configurations, vars...) no están en la lista.
ALLOWED_KS_KEYS="apiVersion kind metadata resources components bases crds patches patchesStrategicMerge patchesJson6902 replacements configMapGenerator generatorOptions namePrefix nameSuffix namespace labels commonLabels commonAnnotations images replicas buildMetadata sortOptions"
ALLOWED_PATCH_KEYS="path patch target options"
ALLOWED_REPLACEMENT_KEYS="path source targets"
ALLOWED_CMGEN_KEYS="name namespace behavior files envs env literals options"
# Campos de spec de un HelmRelease permitidos (lo demás, como postRenderers o dependsOn, se rechaza).
ALLOWED_HR_KEYS="interval serviceAccountName chartRef install upgrade values releaseName timeout test rollback uninstall driftDetection maxHistory"

usage() {
  echo "uso: check-infra.sh [--chart-dir DIR] [--kubernetes-version X.Y.Z] [--schemas DIR] <raíz-del-repo>" >&2
  exit 2
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart_dir=""
kver="1.36.5"
schemas="$here/schemas"
root=""
while (($# > 0)); do
  case "$1" in
    --chart-dir | --kubernetes-version | --schemas)
      (($# >= 2)) || usage
      case "$1" in
        --chart-dir) chart_dir="$2" ;;
        --kubernetes-version) kver="$2" ;;
        --schemas) schemas="$2" ;;
      esac
      shift 2
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [[ -z "$root" ]] || usage
      root="$1"
      shift
      ;;
  esac
done
[[ -n "$root" ]] || usage
[[ "$kver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "versión de Kubernetes inválida: $kver" >&2
  exit 2
}
[[ -d "$root" ]] || {
  echo "no existe la raíz del repo: $root" >&2
  exit 2
}
[[ -d "$schemas" ]] || {
  echo "no existe el directorio de esquemas: $schemas" >&2
  exit 2
}
if [[ -n "$chart_dir" ]]; then
  [[ -f "$chart_dir/Chart.yaml" ]] || {
    echo "--chart-dir sin Chart.yaml: $chart_dir" >&2
    exit 2
  }
  chart_dir="$(cd "$chart_dir" && pwd -P)"
fi
missing=""
for t in helm flux kubeconform gitleaks yq; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [[ -n "$missing" ]]; then
  echo "faltan herramientas:$missing (bash scripts/install-tools.sh helm flux kubeconform gitleaks yq)" >&2
  exit 2
fi
yq --version 2>&1 | grep -q mikefarah || {
  echo "yq debe ser el de mikefarah (v4)" >&2
  exit 2
}
schemas="$(cd "$schemas" && pwd -P)"
root="$(cd "$root" && pwd -P)"
infra="$root/infra"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Nada de lo que corre aquí debe tocar el HOME del usuario ni un cluster.
export HELM_CACHE_HOME="$work/helm/cache" HELM_CONFIG_HOME="$work/helm/config" HELM_DATA_HOME="$work/helm/data"
export KUBECONFIG="$work/sin-kubeconfig"
cache="${CHECK_INFRA_CACHE:-$work/kubeconform-cache}"
mkdir -p "$cache" "$work/charts"

errors=0
rel() { # ruta absoluta -> relativa a la raíz
  local p="$1"
  if [[ "$p" == "$root" ]]; then echo "."; else echo "${p#"$root"/}"; fi
}
err() { # contexto mensaje
  printf 'ERROR %s: %s\n' "$1" "$2" >&2
  errors=$((errors + 1))
}
flat() { tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ $//' | cut -c1-700; }

has_word() { # palabra lista
  local w
  for w in $2; do [[ "$w" == "$1" ]] && return 0; done
  return 1
}

# ¿ruta (relativa al directorio de la kustomization) se queda dentro de infra/?
stays_inside() { # directorio-relativo-a-infra ruta
  local depth=0 part
  local -a parts
  IFS=/ read -r -a parts <<<"$1/$2"
  for part in "${parts[@]}"; do
    case "$part" in
      "" | .) ;;
      ..)
        depth=$((depth - 1))
        ((depth >= 0)) || return 1
        ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
  return 0
}

# --- 1. forma de infra/ ---------------------------------------------------------------
overlays=()
if [[ ! -d "$infra" || -L "$infra" ]]; then
  err infra "no existe la carpeta infra/ en la raíz del repo (o es un enlace simbólico)"
else
  [[ -f "$infra/overlays/prod/kustomization.yaml" ]] ||
    err infra/overlays/prod "falta overlays/prod/kustomization.yaml: todo repo lleva al menos el overlay de prod"
  shopt -s nullglob dotglob
  for d in "$infra"/overlays/*; do
    name="$(basename "$d")"
    if [[ ! -d "$d" ]]; then
      err "$(rel "$d")" "en overlays/ solo van carpetas de entorno: mueve o borra '$name'"
      continue
    fi
    if ! [[ "$name" =~ $RE_DNS && ${#name} -le 63 ]]; then
      err "$(rel "$d")" "nombre de entorno inválido '$name': usa minúsculas, dígitos y guiones (DNS-1123)"
      continue
    fi
    [[ -f "$d/kustomization.yaml" ]] || {
      err "$(rel "$d")" "falta kustomization.yaml en el overlay"
      continue
    }
    overlays+=("$d")
  done
  shopt -u nullglob dotglob
fi

# --- 2. estático sobre todo infra/ (no ejecuta nada) ----------------------------------
static_before=$errors
if [[ -d "$infra" && ! -L "$infra" ]]; then
  while IFS= read -r -d '' l; do
    if ! target="$(realpath "$l" 2>/dev/null)"; then
      err "$(rel "$l")" "enlace simbólico roto: bórralo o apúntalo a un archivo de infra/"
    elif [[ "$target" != "$infra" && "$target" != "$infra"/* ]]; then
      err "$(rel "$l")" "enlace simbólico que sale de infra/: copia el archivo dentro de infra/"
    fi
  done < <(find "$infra" -type l -print0)

  while IFS= read -r -d '' f; do
    r="$(rel "$f")"
    if ! yq e '.' "$f" >/dev/null 2>&1; then
      err "$r" "no es YAML válido"
      continue
    fi
    if [[ -n "$(yq e -N 'select(.kind == "Secret") | .kind' "$f" 2>/dev/null)" ]]; then
      err "$r" "kind: Secret: los secretos no van en el repo; decláralos en Infisical (secrets.infisical) o usa secretKeyRef"
    fi
  done < <(find "$infra" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

  while IFS= read -r -d '' f; do
    r="$(rel "$f")"
    yq e '.' "$f" >/dev/null 2>&1 || continue
    if [[ "$(yq e -N 'tag' "$f" 2>/dev/null | head -n 1)" != "!!map" ]]; then
      err "$r" "la kustomization debe ser un mapa YAML"
      continue
    fi
    if [[ "$(yq e -N '[.. | select(anchor != "" or tag == "!!merge" or kind == "alias")] | length' "$f" 2>/dev/null | head -n 1)" != 0 ]]; then
      err "$r" "la kustomization no admite anclas, alias ni '<<': escribe cada campo completo"
    fi
    for k in $(yq e -N 'keys | .[]' "$f" 2>/dev/null); do
      has_word "$k" "$ALLOWED_KS_KEYS" ||
        err "$r" "campo '$k' no permitido: ejecuta o trae contenido de fuera, o no se reconoce; usa solo resources, patches y generadores de ConfigMap"
    done
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      case "${k%%:*}" in
        patches | patchesJson6902) has_word "${k#*:}" "$ALLOWED_PATCH_KEYS" ;;
        replacements) has_word "${k#*:}" "$ALLOWED_REPLACEMENT_KEYS" ;;
        configMapGenerator) has_word "${k#*:}" "$ALLOWED_CMGEN_KEYS" ;;
      esac || err "$r" "campo '${k#*:}' no permitido dentro de ${k%%:*} (sensible a mayúsculas)"
    done < <(yq e -N '
      ((.patches // [])[] | select(tag == "!!map") | keys | .[] | "patches:" + .),
      ((.patchesJson6902 // [])[] | select(tag == "!!map") | keys | .[] | "patchesJson6902:" + .),
      ((.replacements // [])[] | select(tag == "!!map") | keys | .[] | "replacements:" + .),
      ((.configMapGenerator // [])[] | select(tag == "!!map") | keys | .[] | "configMapGenerator:" + .)' "$f" 2>/dev/null)
    kdir="$(dirname "$f")"
    kdir_rel="${kdir#"$infra"}"
    kdir_rel="${kdir_rel#/}"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      case "$p" in
        *://* | git@* | *github.com/* | *'?ref='* | *'?version='*)
          err "$r" "'$p' es una base remota: solo se admiten rutas locales dentro de infra/"
          ;;
        /*)
          err "$r" "'$p' es una ruta absoluta: usa una ruta relativa dentro de infra/"
          ;;
        *)
          stays_inside "$kdir_rel" "$p" ||
            err "$r" "'$p' sale de infra/: solo se admiten rutas dentro de infra/"
          ;;
      esac
    done < <(yq e -N '
      ((.resources // [])[], (.components // [])[], (.bases // [])[], (.crds // [])[],
       ((.patchesStrategicMerge // [])[] | select(tag == "!!str") | select(contains("\n") | not)),
       ((.patches // [])[] | .path), ((.patchesJson6902 // [])[] | .path),
       ((.replacements // [])[] | select(tag == "!!str")),
       ((.replacements // [])[] | select(tag == "!!map") | .path),
       ((.configMapGenerator // [])[] | (((.files // [])[] | sub("^[^=]*=";"")), (.envs // [])[], .env)),
       (.openapi.path)
      ) | select(tag == "!!str")' "$f" 2>/dev/null)
  done < <(find "$infra" -type f \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) -print0)
fi
static_bad=$((errors - static_before))

# --- reglas sobre manifiestos ya construidos (pasos 3 y 5) ----------------------------
# check_rendered <archivo con documentos> <contexto> <directorio de trabajo>
# Deja en $3/docN.yml cada documento y aplica kinds prohibidos, namespace y kubeconform.
check_rendered() {
  local file="$1" ctx="$2" d="$3" doc api kind name ns g out rc line
  mkdir -p "$d/docs"
  yq e -N -s "\"$d/docs/doc\" + \$index" "$file" 2>/dev/null || {
    err "$ctx" "no se pudo leer el resultado como YAML"
    return 0
  }
  for doc in "$d"/docs/doc*.yml; do
    [[ -e "$doc" ]] || continue
    IFS='|' read -r api kind name ns < <(yq e '(.apiVersion // "") + "|" + (.kind // "") + "|" + (.metadata.name // "") + "|" + (.metadata.namespace // "")' "$doc")
    [[ -n "$kind" ]] || continue
    g=""
    if [[ "$api" == */* ]]; then g="${api%%/*}"; fi
    if [[ "$kind" == Secret ]]; then
      err "$ctx" "genera un Secret ($name): los secretos no van en el repo; usa Infisical (secrets.infisical) o secretKeyRef"
    elif has_word "$kind" "$FORBIDDEN_KINDS"; then
      err "$ctx" "kind prohibido $kind ($name): lo aplica solo la plataforma"
    elif has_word "$kind" "$CLUSTER_KINDS"; then
      err "$ctx" "kind de alcance cluster $kind ($name): un tenant solo aplica recursos de su namespace"
    elif has_word "$g" "$FORBIDDEN_GROUPS"; then
      err "$ctx" "kind prohibido $kind del grupo $g ($name): lo aplica solo la plataforma"
    fi
    if [[ "$kind" == ServiceAccount && "$name" == tenant-reconciler ]]; then
      err "$ctx" "ServiceAccount tenant-reconciler: lo crea la plataforma; no lo declares"
    fi
    if [[ -n "$ns" ]]; then
      err "$ctx" "$kind $name lleva metadata.namespace '$ns': quítalo, el namespace lo pone la plataforma"
    fi
  done
  rc=0
  out="$(kubeconform -strict -kubernetes-version "$kver" -cache "$cache" -schema-location default \
    -schema-location "$schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    -output text "$file" 2>&1)" || rc=$?
  if ((rc != 0)); then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      err "$ctx" "kubeconform: ${line#"$file" - }"
    done <<<"$out"
  fi
}

# check_oci <documento> <contexto>
check_oci() {
  local doc="$1" ctx="$2" v
  v="$(yq e '.spec.url // ""' "$doc")"
  [[ "$v" =~ ^oci://ghcr\.io/kidcuauh/charts/[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    err "$ctx" "OCIRepository: spec.url '$v' debe ser ${CI_REPO_URL_PREFIX}<chart>"
  v="$(yq e '(.spec.ref // {}) | keys | join(",")' "$doc")"
  [[ "$v" == digest ]] ||
    err "$ctx" "OCIRepository: spec.ref debe tener solo digest (hoy: '${v:-vacío}'); el chart se fija por digest"
  v="$(yq e '.spec.ref.digest // ""' "$doc")"
  [[ "$v" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    err "$ctx" "OCIRepository: spec.ref.digest '$v' debe ser sha256:<64 hex>"
  [[ "$(yq e '.spec.verify.provider // ""' "$doc")" == cosign ]] ||
    err "$ctx" "OCIRepository: falta spec.verify.provider: cosign"
  if [[ "$(yq e '(.spec.verify.matchOIDCIdentity // []) | length' "$doc")" -lt 1 ]]; then
    err "$ctx" "OCIRepository: falta spec.verify.matchOIDCIdentity con la identidad de release-chart.yml"
  else
    [[ "$(ISS="$OIDC_ISSUER" SUB="$OIDC_SUBJECT" yq e '[.spec.verify.matchOIDCIdentity[] | select(.issuer != strenv(ISS) or .subject != strenv(SUB))] | length' "$doc")" == 0 ]] ||
      err "$ctx" "OCIRepository: matchOIDCIdentity debe ser exactamente el issuer y el subject de release-chart.yml (docs/check-infra.md)"
  fi
  [[ "$(yq e '.spec.serviceAccountName | tag' "$doc")" == '!!null' ]] ||
    err "$ctx" "OCIRepository: spec.serviceAccountName no se admite: el chart se baja sin credencial"
  v="$(yq e '.spec.provider // "generic"' "$doc")"
  [[ "$v" == generic ]] ||
    err "$ctx" "OCIRepository: spec.provider '$v' no se admite: solo generic (sin credenciales de nube)"
  [[ "$(yq e '.spec.insecure // false' "$doc")" == false ]] ||
    err "$ctx" "OCIRepository: spec.insecure no se admite"
  for v in secretRef certSecretRef proxySecretRef verify.secretRef; do
    [[ "$(yq e '.spec.'"$v"' | tag' "$doc")" == '!!null' ]] ||
      err "$ctx" "OCIRepository: spec.$v no se admite: el chart es público y se baja sin credencial"
  done
}

# check_helmrelease <documento> <contexto> <archivo con los nombres de OCIRepository del overlay>
check_helmrelease() {
  local doc="$1" ctx="$2" names="$3" v
  [[ "$(yq e '.spec.chartRef.kind // ""' "$doc")" == OCIRepository ]] ||
    err "$ctx" "HelmRelease: debe usar spec.chartRef de kind OCIRepository"
  v="$(yq e '.spec.chartRef.name // ""' "$doc")"
  grep -qxF -- "$v" "$names" ||
    err "$ctx" "HelmRelease: spec.chartRef.name '$v' no es un OCIRepository del mismo overlay"
  [[ "$(yq e '.spec.chartRef.namespace' "$doc")" == null ]] ||
    err "$ctx" "HelmRelease: spec.chartRef.namespace no se admite: el OCIRepository vive en el mismo namespace"
  v="$(yq e '.spec.serviceAccountName // ""' "$doc")"
  [[ "$v" == tenant-reconciler ]] ||
    err "$ctx" "HelmRelease: spec.serviceAccountName debe ser tenant-reconciler (hoy: '${v:-vacío}')"
  for v in chart kubeConfig targetNamespace storageNamespace valuesFrom; do
    [[ "$(yq e '.spec.'"$v"' | tag' "$doc")" == '!!null' ]] ||
      err "$ctx" "HelmRelease: spec.$v no se admite (solo chartRef y values en línea)"
  done
  for v in $(yq e '(.spec // {}) | keys | .[]' "$doc" 2>/dev/null); do
    has_word "$v" "chart kubeConfig targetNamespace storageNamespace valuesFrom" && continue
    has_word "$v" "$ALLOWED_HR_KEYS" ||
      err "$ctx" "HelmRelease: spec.$v no se admite (por ejemplo postRenderers y dependsOn los decide la plataforma)"
  done
  for v in install.createNamespace install.crds upgrade.crds; do
    [[ "$(yq e '.spec.'"$v"' | tag' "$doc" 2>/dev/null)" == '!!null' ]] ||
      err "$ctx" "HelmRelease: spec.$v no se admite"
  done
}

# render_release <documento> <contexto> <directorio de trabajo> <directorio de OCIRepository>
render_release() {
  local doc="$1" ctx="$2" d="$3" ocidir="$4" ref url digest chart rname cpath msg rc=0
  ref="$(yq e '.spec.chartRef.name // ""' "$doc")"
  if ! [[ "$ref" =~ $RE_DNS && -f "$ocidir/$ref" ]]; then
    return 0 # check_helmrelease ya lo reportó
  fi
  read -r url digest <"$ocidir/$ref"
  chart="${url##*/}"
  if [[ -n "$chart_dir" ]]; then
    cpath="$chart_dir"
    if [[ "$(yq e '.name' "$chart_dir/Chart.yaml")" != "$chart" ]]; then
      err "$ctx" "el chart de --chart-dir se llama '$(yq e '.name' "$chart_dir/Chart.yaml")' y el OCIRepository pide '$chart'"
      return 0
    fi
  else
    [[ "$chart" =~ $RE_DNS && "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 0
    cpath="$work/charts/${digest#sha256:}/$chart"
    if [[ -f "$work/charts/${digest#sha256:}.fail" ]]; then return 0; fi
    if [[ ! -d "$cpath" ]]; then
      if ! msg="$(helm pull "oci://ghcr.io/kidcuauh/charts/$chart@$digest" --untar --untardir "$work/charts/${digest#sha256:}" 2>&1)"; then
        : >"$work/charts/${digest#sha256:}.fail"
        err "$ctx" "no se pudo bajar el chart $chart@$digest (¿digest publicado y paquete público?): $(printf '%s' "$msg" | flat)"
        return 0
      fi
    fi
  fi
  rname="$(yq e '.spec.releaseName // .metadata.name' "$doc")"
  if ! [[ "$rname" =~ $RE_DNS && ${#rname} -le 53 ]]; then
    err "$ctx" "HelmRelease: spec.releaseName inválido '$rname': minúsculas, dígitos y guiones, hasta 53 caracteres"
    return 0
  fi
  yq e '.spec.values // {}' "$doc" >"$d/values.yaml"
  helm template --namespace check-infra -f "$d/values.yaml" -- "$rname" "$cpath" >"$d/helm.yaml" 2>"$d/helm.err" || rc=$?
  if ((rc != 0)); then
    err "$ctx" "helm template falló: $(flat <"$d/helm.err")"
    return 0
  fi
  check_rendered "$d/helm.yaml" "$ctx (helm template)" "$d/helm"
}

# --- 3 a 5. por overlay ---------------------------------------------------------------
if ((static_bad > 0)); then
  echo "aviso: errores estáticos en infra/: no se construye ningún overlay (corrígelos primero)" >&2
elif ((${#overlays[@]} > 0)); then
  cat >"$work/ks.yaml" <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: check-infra
  namespace: check-infra
spec:
  interval: 1m
  path: ./
  prune: false
  sourceRef:
    kind: GitRepository
    name: check-infra
EOF
  for ov in "${overlays[@]}"; do
    env="$(basename "$ov")"
    ctx="$(rel "$ov")"
    d="$work/ov-$env"
    mkdir -p "$d/oci"
    if ! flux build kustomization check-infra -n check-infra --path "$ov" \
      --kustomization-file "$work/ks.yaml" --dry-run >"$d/build.yaml" 2>"$d/build.err"; then
      err "$ctx" "flux build falló: $(flat <"$d/build.err")"
      continue
    fi
    check_rendered "$d/build.yaml" "$ctx" "$d/build"
    # OCIRepository primero (los HelmRelease los referencian), luego HelmRelease.
    : >"$d/oci-names"
    for doc in "$d"/build/docs/doc*.yml; do
      [[ -e "$doc" ]] || continue
      kind="$(yq e '.kind // ""' "$doc")"
      [[ "$kind" == OCIRepository ]] || continue
      name="$(yq e '.metadata.name // ""' "$doc")"
      if ! [[ "$name" =~ $RE_DNS ]]; then
        err "$ctx" "OCIRepository con nombre inválido '$name'"
        continue
      fi
      echo "$name" >>"$d/oci-names"
      echo "$(yq e '.spec.url // ""' "$doc") $(yq e '.spec.ref.digest // ""' "$doc")" >"$d/oci/$name"
      check_oci "$doc" "$ctx OCIRepository/$name"
    done
    n=0
    for doc in "$d"/build/docs/doc*.yml; do
      [[ -e "$doc" ]] || continue
      kind="$(yq e '.kind // ""' "$doc")"
      [[ "$kind" == HelmRelease ]] || continue
      name="$(yq e '.metadata.name // ""' "$doc")"
      [[ "$name" =~ $RE_DNS ]] || {
        err "$ctx" "HelmRelease con nombre inválido '$name'"
        continue
      }
      n=$((n + 1))
      check_helmrelease "$doc" "$ctx HelmRelease/$name" "$d/oci-names"
      mkdir -p "$d/rel-$name"
      render_release "$doc" "$ctx HelmRelease/$name" "$d/rel-$name" "$d/oci"
    done
    ((n > 0)) || err "$ctx" "el overlay no declara ningún HelmRelease"
  done
fi

# --- 6. gitleaks solo sobre infra/ ----------------------------------------------------
# Configuración por defecto de gitleaks, fijada aquí: una .gitleaks.toml, un .gitleaksignore
# o un comentario gitleaks:allow dentro de infra/ no pueden apagar la revisión. La lista de
# rutas que gitleaks ignora por defecto (node_modules, vendor, *.svg, gitleaks.toml...) tampoco:
# se escanea una copia de infra/ con nombres neutros (f0001.txt). Un archivo binario o
# comprimido se rechaza, porque gitleaks no mira dentro.
if [[ -d "$infra" && ! -L "$infra" ]]; then
  scan="$work/scan"
  mkdir -p "$scan"
  : >"$work/scan-map"
  i=0
  while IFS= read -r -d '' f; do
    r="$(rel "$f")"
    if [[ -s "$f" ]] && ! LC_ALL=C grep -Iq . "$f" 2>/dev/null; then
      err "$r" "archivo binario o comprimido: en infra/ solo va texto, para que se pueda revisar"
      continue
    fi
    i=$((i + 1))
    n="$(printf 'f%05d.txt' "$i")"
    cp "$f" "$scan/$n" 2>/dev/null || {
      err "$r" "no se pudo leer el archivo"
      continue
    }
    printf '%s\t%s\n' "$n" "$r" >>"$work/scan-map"
  done < <(find "$infra" -type f -print0)
  printf '[extend]\nuseDefault = true\n' >"$work/gitleaks.toml"
  : >"$work/gitleaks-ignore"
  rc=0
  gitleaks dir "$scan" --config "$work/gitleaks.toml" --gitleaks-ignore-path "$work/gitleaks-ignore" \
    --ignore-gitleaks-allow --redact --no-banner --no-color -f json -r "$work/gitleaks.json" >"$work/gitleaks.out" 2>&1 || rc=$?
  if ((rc == 1)); then
    n=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      n=$((n + 1))
      rule="${line%% *}"
      loc="${line#* }"
      fname="$(basename "${loc%:*}")"
      orig="$(awk -F '\t' -v k="$fname" '$1 == k { print $2; exit }' "$work/scan-map")"
      err infra "gitleaks: credencial en el repo ($rule en ${orig:-infra/}:${loc##*:}): sácala de infra/ y rótala; los secretos van en Infisical"
    done < <(yq e -p=json '.[] | .RuleID + " " + .File + ":" + (.StartLine | tostring)' "$work/gitleaks.json" 2>/dev/null)
    ((n > 0)) || err infra "gitleaks: encontró credenciales en infra/"
  elif ((rc != 0)); then
    err infra "gitleaks falló: $(flat <"$work/gitleaks.out")"
  fi
fi

if ((errors > 0)); then
  printf '%d error(es) en %s\n' "$errors" "$root" >&2
  exit 1
fi
echo "check-infra OK: ${#overlays[@]} overlay(s) en $(rel "$infra")"
