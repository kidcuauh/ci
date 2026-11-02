#!/usr/bin/env bash
# Pruebas de scripts/check-infra.sh: sin cluster ni secretos. Uso: test-check-infra.sh
# Requiere helm, flux, kubeconform, gitleaks y yq en el PATH (scripts/install-tools.sh).
# Los casos viven en tests/check-infra/cases/<caso>/:
#   expect    texto que debe aparecer en la salida de un caso negativo (o "check-infra OK" en uno positivo)
#   expect2   texto adicional opcional
#   yq        mutaciones: una por línea, "<ruta relativa a la raíz> <expresión yq>"
#   files/    archivos que se copian encima del repo de prueba
#   remove    rutas a borrar (una por línea)
# Cada caso parte de una copia de examples/solo-prod. Los casos que necesitan un literal de
# credencial lo generan aquí, concatenando cadenas, para que no exista en ningún archivo del repo.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/check-infra.sh"
cases="$root/tests/check-infra/cases"

for t in helm flux kubeconform gitleaks yq; do
  command -v "$t" >/dev/null || {
    echo "falta la herramienta: $t" >&2
    exit 2
  }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export CHECK_INFRA_CACHE="$work/cache"
mkdir -p "$CHECK_INFRA_CACHE"

failures=0
total=0
fail() {
  echo "FALLA: $*" >&2
  failures=$((failures + 1))
}
pass() { echo "ok: $*"; }

# Chart bajo prueba: el del repo; si aún no existe, uno mínimo desechable.
if [[ -f "$root/charts/app/Chart.yaml" && -f "$root/charts/app/values.schema.json" ]]; then
  chart="$root/charts/app"
else
  chart="$work/chart/app"
  mkdir -p "$chart/templates"
  printf 'apiVersion: v2\nname: app\nversion: 0.0.1\n' >"$chart/Chart.yaml"
  cat >"$chart/values.yaml" <<'EOF'
image: {repository: "", tag: "", digest: ""}
imagePullSecrets: []
priorityClassName: ""
env: []
web: {}
EOF
  cat >"$chart/values.schema.json" <<'EOF'
{"$schema": "http://json-schema.org/draft-07/schema#", "type": "object", "additionalProperties": false,
 "properties": {"image": {"type": "object"}, "imagePullSecrets": {"type": "array"},
   "priorityClassName": {"type": "string"}, "env": {"type": "array"}, "web": {"type": "object"}}}
EOF
  cat >"$chart/templates/deploy.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: app
          image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
EOF
fi
echo "chart bajo prueba: ${chart#"$root"/}"

# Genera una cadena con forma de token de GitHub sin que exista como literal en el repo.
cred() { printf '%s%s%s' "gh" "p_" "R7kQ2mX9vB4nL8sT1wZ5cD3fG6hJ0yA2eU4i"; }

prepare() { # caso -> directorio de trabajo con el repo de prueba
  local n="$1" d="$work/case-$1" line path expr
  rm -rf "$d"
  mkdir -p "$d"
  cp -R "$root/examples/solo-prod/." "$d/"
  if [[ -d "$cases/$n/files" ]]; then cp -R "$cases/$n/files/." "$d/"; fi
  if [[ -f "$cases/$n/remove" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && rm -rf "${d:?}/$line"
    done <"$cases/$n/remove"
  fi
  if [[ -f "$cases/$n/yq" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      path="${line%% *}"
      expr="${line#* }"
      yq e -i "$expr" "$d/$path"
    done <"$cases/$n/yq"
  fi
  case "$n" in
    enlace-fuera) ln -s /etc "$d/infra/base/enlace" ;;
    credencial-en-infra) printf 'token: %s\n' "$(cred)" >"$d/infra/base/mi-app/notas.txt" ;;
    gitleaks-allow)
      printf 'token: %s # gitleaks:allow\n' "$(cred)" >"$d/infra/base/mi-app/notas.txt"
      printf '[allowlist]\nregexes = [".*"]\n' >"$d/infra/.gitleaks.toml"
      printf '*\n' >"$d/infra/.gitleaksignore"
      ;;
    gitleaks-svg) printf '<svg>token=%s</svg>\n' "$(cred)" >"$d/infra/base/mi-app/conf.svg" ;;
    gitleaks-node-modules)
      mkdir -p "$d/infra/node_modules"
      printf 'token=%s\n' "$(cred)" >"$d/infra/node_modules/a.env"
      ;;
    archivo-binario) printf '\037\213\010\000\001\002\003' >"$d/infra/base/mi-app/datos.tgz" ;;
    credencial-fuera)
      printf 'token: %s\n' "$(cred)" >"$d/README.txt"
      mkdir -p "$d/src"
      printf 'const t = "%s"\n' "$(cred)" >"$d/src/config.js"
      ;;
  esac
  echo "$d"
}

run() { # directorio args... -> salida en $out, código en $rc
  rc=0
  out="$(bash "$script" "$@" 2>&1)" || rc=$?
}

# --- positivos: los ejemplos ---------------------------------------------------------
for ex in minimal solo-prod; do
  total=$((total + 1))
  run --chart-dir "$chart" "$root/examples/$ex"
  if ((rc == 0)) && grep -qF "check-infra OK" <<<"$out"; then
    pass "examples/$ex"
  else
    fail "examples/$ex debe pasar (rc=$rc): $out"
  fi
done

# --- casos de tests/check-infra/cases ------------------------------------------------
for dir in "$cases"/*/; do
  n="$(basename "$dir")"
  total=$((total + 1))
  d="$(prepare "$n")"
  run --chart-dir "$chart" "$d"
  want="$(head -n 1 "$cases/$n/expect")"
  if [[ "$want" == "check-infra OK" ]]; then
    if ((rc == 0)) && grep -qF "$want" <<<"$out"; then pass "$n"; else fail "$n debe pasar (rc=$rc): $out"; fi
    continue
  fi
  if ((rc != 1)); then
    fail "$n debe fallar con rc=1 (rc=$rc): $out"
    continue
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    fail "$n: falta el texto «$want» en: $out"
    continue
  fi
  if [[ -f "$cases/$n/expect2" ]] && ! grep -qF -- "$(head -n 1 "$cases/$n/expect2")" <<<"$out"; then
    fail "$n: falta el texto «$(head -n 1 "$cases/$n/expect2")» en: $out"
    continue
  fi
  pass "$n"
done

# --- un error estático no deja construir nada ----------------------------------------
total=$((total + 1))
d="$(prepare base-remota)"
run --chart-dir "$chart" "$d"
if grep -qF "no se construye ningún overlay" <<<"$out" && ! grep -qF "flux build" <<<"$out"; then
  pass "estático antes de construir"
else
  fail "con errores estáticos no debe correr flux build: $out"
fi

# --- argumentos y herramientas (código 2) y sin infra/ --------------------------------
# check_exit <nombre> <rc esperado> <texto esperado o vacío>  (usa $rc y $out de la última ejecución)
check_exit() {
  total=$((total + 1))
  if ((rc != $2)); then
    fail "$1: rc=$rc, se esperaba $2: $out"
  elif [[ -n "$3" ]] && ! grep -qF -- "$3" <<<"$out"; then
    fail "$1: falta el texto «$3» en: $out"
  else
    pass "$1: rc=$2"
  fi
}

run
check_exit "sin argumentos" 2 ""
run --kubernetes-version 1.x "$root/examples/solo-prod"
check_exit "versión inválida" 2 "versión de Kubernetes inválida"
run --schemas "$work/no-existe" "$root/examples/solo-prod"
check_exit "esquemas inexistentes" 2 "no existe el directorio de esquemas"
rc=0
out="$(PATH="/usr/bin:/bin" "$(command -v bash)" "$script" "$root/examples/solo-prod" 2>&1)" || rc=$?
check_exit "sin herramientas" 2 "faltan herramientas"
mkdir -p "$work/vacio"
run --chart-dir "$chart" "$work/vacio"
check_exit "sin infra/" 1 "no existe la carpeta infra/"

echo "$((total - failures)) de $total pruebas pasaron"
((failures == 0))
