#!/usr/bin/env bash
# Funciones y expresiones regulares comunes de los scripts deploy-*.sh. Se carga con
# `source`; no se ejecuta. Documentación: docs/deploy.md.
# Escribe en bash 3.2 (macOS) y 5 (runners): sin arreglos asociativos ni ${x,,}.
# shellcheck disable=SC2034 # las RE_* las usan los scripts que cargan este archivo

RE_NAME='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
RE_SHA40='^[0-9a-f]{40}$'
RE_SHATAG='^sha-[0-9a-f]{12}$'
RE_SEMVER='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
RE_VERSION='^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
RE_DIGEST='^sha256:[0-9a-f]{64}$'
RE_OWNER='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
RE_SLUG='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
RE_IMAGE='^ghcr\.io/[a-z0-9]([a-z0-9-]*[a-z0-9])?/[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
RE_REMOTE='^[A-Za-z0-9._-]+$'

# Los mensajes van a stderr: stdout de varios scripts son datos (digest, resolve).
# Un mensaje nunca imprime el valor inválido: un valor con "::" inyectaría comandos.
fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}
warn() { printf '::warning::%s\n' "$*" >&2; }
notice() { printf '::notice::%s\n' "$*" >&2; }

# abspath ruta: la ruta absoluta de un archivo existente, resuelta desde el directorio
# actual. Los scripts que hacen `cd` al repo la usan antes, para que una ruta relativa
# al workspace (ci/scripts/...) siga valiendo después del cd.
abspath() {
  local d
  [[ -f "$1" ]] || fail "no existe el archivo indicado"
  d="$(cd "$(dirname "$1")" && pwd -P)" || fail "no existe el directorio del archivo indicado"
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# Minúsculas sin ${x,,} (bash 3.2).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# set_output clave valor: a $GITHUB_OUTPUT; sin él (pruebas), a stdout.
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

# set_output_multiline clave: el valor llega por stdin; delimitador aleatorio.
set_output_multiline() {
  local d val
  d="ghadelimiter_${RANDOM}${RANDOM}${RANDOM}"
  val="$(cat)"
  {
    printf '%s<<%s\n' "$1" "$d"
    if [[ -n "$val" ]]; then printf '%s\n' "$val"; fi
    printf '%s\n' "$d"
  } >>"${GITHUB_OUTPUT:-/dev/stdout}"
}

# summary texto...: agrega una línea al resumen del job, si existe.
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi
  return 0
}

# patch_value repo ref env app clave: image.tag o image.digest de un patch en una
# referencia de git (vacío si falta el archivo o la clave).
patch_value() {
  local v
  v="$(git -C "$1" show "$2:infra/overlays/$3/$4.patch.yaml" 2>/dev/null |
    yq e ".spec.values.image.$5 // \"\"" - 2>/dev/null)" || v=""
  printf '%s' "$v"
}

# last_source repo env app [ref]: el Source-SHA del último bump de ese ambiente y app,
# por primer padre de ref (HEAD por defecto): el commit más reciente que toca
# infra/overlays/<env>/<app>.patch.yaml y trae los trailers Deploy-Env, Deploy-App y
# un Source-SHA de 40 hex. Vacío si no hay.
last_source() {
  local repo="$1" env="$2" app="$3" ref="${4:-HEAD}" file c trl src
  file="infra/overlays/$env/$app.patch.yaml"
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    trl="$(git -C "$repo" show -s --format=%B "$c" | git interpret-trailers --parse)"
    grep -qxF "Deploy-Env: $env" <<<"$trl" || continue
    grep -qxF "Deploy-App: $app" <<<"$trl" || continue
    src="$(sed -n 's/^Source-SHA: //p' <<<"$trl" | head -n 1)"
    [[ "$src" =~ $RE_SHA40 ]] || continue
    printf '%s\n' "$src"
    return 0
  done < <(git -C "$repo" log --first-parent --format=%H "$ref" -- "$file")
  return 0
}

# Llaves públicas de github.com (https://api.github.com/meta, ssh_keys; leídas el
# 2026-11-01). No se incluye la RSA.
GITHUB_KNOWN_HOSTS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg='

# git_auth repo slug: prepara la autenticación de git del paso que la llama (se hace
# `source` del lib y se llama en el mismo shell que usa git).
#   DEPLOY_READ_TOKEN  github.token, para leer
#   DEPLOY_PUSH_TOKEN  secreto push_token (opcional): una llave SSH privada (deploy key)
#                      o un token HTTPS; vacío = se usa el de lectura también para empujar
# Nunca escribe el token en .git/config ni en $GITHUB_ENV: usa variables de entorno del
# proceso (GIT_CONFIG_*) y enmascara el valor antes de exportarlo. Sin tokens (pruebas)
# no hace nada.
git_auth() {
  local repo="$1" slug="$2" read_tok="${DEPLOY_READ_TOKEN:-}" push_tok="${DEPLOY_PUSH_TOKEN:-}"
  local tok b64 key kh host=github.com
  [[ -n "$read_tok" || -n "$push_tok" ]] || return 0
  [[ "$slug" =~ $RE_SLUG ]] || fail "repositorio inválido"
  tok="$read_tok"
  if [[ "$push_tok" == -----BEGIN* ]]; then
    [[ -n "${RUNNER_TEMP:-}" ]] || fail "falta RUNNER_TEMP"
    key="$RUNNER_TEMP/deploy-key"
    kh="$RUNNER_TEMP/deploy-known-hosts"
    (
      umask 077
      printf '%s\n' "$push_tok" >"$key"
      printf '%s\n' "$GITHUB_KNOWN_HOSTS" >"$kh"
    )
    git -C "$repo" remote set-url --push origin "git@${host}:${slug}.git"
    export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=yes -o BatchMode=yes"
  elif [[ -n "$push_tok" ]]; then
    tok="$push_tok"
  fi
  [[ -n "$tok" ]] || fail "falta un token de lectura"
  b64="$(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"
  printf '::add-mask::%s\n' "$b64"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.https://${host}/.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $b64"
  # Los tokens crudos ya no hacen falta: los hijos (kubectl, yq, helm, gitleaks) no los heredan.
  unset DEPLOY_READ_TOKEN DEPLOY_PUSH_TOKEN
}
