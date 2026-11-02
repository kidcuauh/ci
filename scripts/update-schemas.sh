#!/usr/bin/env bash
# Regenera schemas/ (JSON Schema para kubeconform) desde los CRD oficiales fijados por
# URL y sha256. Uso: update-schemas.sh [directorio-de-salida]  (por defecto schemas/)
# Requiere curl, yq y python3. Para subir una versión: cambia la URL, calcula el sha256
# del archivo nuevo (shasum -a 256), corre este script y revisa el diff de schemas/.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/schemas}"
# Se borra y se regenera: solo una carpeta llamada schemas, vacía o que aún no existe.
if [[ "$(basename "$out")" != schemas ]] && [[ -e "$out" && -n "$(ls -A "$out")" ]]; then
  echo "el directorio de salida existe y no se llama schemas: $out" >&2
  exit 2
fi
for t in curl yq python3; do
  command -v "$t" >/dev/null || {
    echo "falta la herramienta: $t" >&2
    exit 2
  }
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fuente URL SHA256 grupo:Kind:versión...
fuente() {
  local url="$1" sha="$2" f="$work/src.yaml"
  shift 2
  curl -fsSL --retry 3 --retry-all-errors -o "$f" "$url"
  [[ "$(sha256_of "$f")" == "$sha" ]] || {
    echo "sha256 no coincide: $url" >&2
    exit 1
  }
  yq -o=json '.' "$f" | python3 -I "$root/scripts/crd-to-schema.py" --out "$work/out" "$@"
  echo "ok: $url"
}

# Flux 2.10.0
fuente https://github.com/fluxcd/flux2/releases/download/v2.10.0/install.yaml \
  a8c838ccd9be5d30eba9df87cd229b7c4eb80c0049fba1bc3b9840829f267f28 \
  source.toolkit.fluxcd.io:OCIRepository:v1 source.toolkit.fluxcd.io:GitRepository:v1 \
  helm.toolkit.fluxcd.io:HelmRelease:v2 kustomize.toolkit.fluxcd.io:Kustomization:v1

# Operador de Infisical 0.11.16
fuente https://raw.githubusercontent.com/Infisical/kubernetes-operator/infisical-k8-operator/v0.11.16/config/crd/bases/secrets.infisical.com_infisicalstaticsecrets.yaml \
  22f35733efdfb91c009fe462994ed8b2e489799ee2ba2a5814507a880f8ea6c3 \
  secrets.infisical.com:InfisicalStaticSecret:v1beta1

# CloudNativePG 1.30.1
cnpg=https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.30.1/config/crd/bases/postgresql.cnpg.io
fuente "$cnpg"_clusters.yaml d255176c368727b8ee84893bb2f37b5c5578a497e6ee7461a81fa6f3f80e552b postgresql.cnpg.io:Cluster:v1
fuente "$cnpg"_backups.yaml c9c015781d32d12ec4d8dc31ce1c4fbe2574f640993d8587f77c079286f2c388 postgresql.cnpg.io:Backup:v1
fuente "$cnpg"_scheduledbackups.yaml fcd133df3056601c1a306a4bf0cd2fac6413c99b88b459e0296321299f7e5062 postgresql.cnpg.io:ScheduledBackup:v1
fuente "$cnpg"_poolers.yaml 0232ac0b0390eb5886704d68bfb9fa1d1b3ebc15093b0f49bf278af09c4892c8 postgresql.cnpg.io:Pooler:v1

# Percona Operator for MongoDB 1.23.1
fuente https://raw.githubusercontent.com/percona/percona-server-mongodb-operator/v1.23.1/deploy/crd.yaml \
  a0ff45ad02075380e5a968d5cf30a96c950ccee7cfef4be557fd8695473e66fe \
  psmdb.percona.com:PerconaServerMongoDB:v1 psmdb.percona.com:PerconaServerMongoDBBackup:v1 \
  psmdb.percona.com:PerconaServerMongoDBRestore:v1

# Reemplaza la salida entera: un kind que se quita de la lista desaparece.
rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -R "$work/out" "$out"
find "$out" -type f | sort | sed "s|^$out/|schemas: |"
