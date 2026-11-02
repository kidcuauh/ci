#!/usr/bin/env bash
# Escribe imágenes en infra/ del repo y empuja a main. Uso:
#   deploy-bump.sh --repo DIR --source SHA --set ENV APP TAG DIGEST [--set ...]
#                  [--order-guard] [--check-infra SCRIPT [--check-infra-arg ARG]...]
#                  [--max-retries 5] [--remote origin]
# Un commit por app y ambiente (solo infra/overlays/<env>/<app>.patch.yaml), todos en
# un solo push sin force. Antes de empujar renderiza el overlay y comprueba que sale el
# tag y el digest nuevos; con --check-infra corre además esa verificación. Un push
# rechazado por carrera se reintenta desde la punta fresca de main, reevaluando todo.
# Salidas: changed, commit_sha, previous_digest y new_digest (una línea
# "<env>/<app> <digest>" por app escrita). Documentación: docs/deploy.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

repo=""
source_sha=""
order_guard=0
check_script=""
check_args=()
max_retries=5
remote=origin
S_ENV=()
S_APP=()
S_TAG=()
S_DIG=()
while (($# > 0)); do
  case "$1" in
    --order-guard)
      order_guard=1
      shift
      ;;
    --set)
      (($# >= 5)) || fail "--set pide ENV APP TAG DIGEST"
      S_ENV+=("$2")
      S_APP+=("$3")
      S_TAG+=("$4")
      S_DIG+=("$5")
      shift 5
      ;;
    --repo | --source | --check-infra | --check-infra-arg | --max-retries | --remote)
      (($# >= 2)) || fail "argumento sin valor"
      case "$1" in
        --repo) repo="$2" ;;
        --source) source_sha="$2" ;;
        --check-infra) check_script="$(abspath "$2")" ;;
        --check-infra-arg) check_args+=("$2") ;;
        --max-retries) max_retries="$2" ;;
        --remote) remote="$2" ;;
      esac
      shift 2
      ;;
    *) fail "argumento desconocido" ;;
  esac
done

[[ -d "$repo" ]] || fail "--repo: no es un directorio"
repo="$(cd "$repo" && pwd -P)"
[[ "$source_sha" =~ $RE_SHA40 ]] || fail "--source inválido"
[[ "$remote" =~ $RE_REMOTE ]] || fail "--remote inválido"
[[ "$max_retries" =~ ^[0-9]+$ ]] || fail "--max-retries inválido"
nsets=${#S_ENV[@]}
((nsets > 0)) || fail "falta al menos un --set"
i=0
while ((i < nsets)); do
  e="${S_ENV[$i]}"
  if ! [[ "$e" =~ $RE_NAME ]] || ((${#e} > 63)); then fail "ambiente inválido"; fi
  [[ "${S_APP[$i]}" =~ $RE_NAME ]] || fail "app inválida"
  if [[ "$e" == prod ]]; then
    [[ "${S_TAG[$i]}" =~ $RE_SEMVER ]] || fail "tag inválido: en prod debe ser X.Y.Z"
  else
    [[ "${S_TAG[$i]}" =~ $RE_SHATAG ]] || fail "tag inválido: fuera de prod debe ser sha-<12 hex>"
  fi
  [[ "${S_DIG[$i]}" =~ $RE_DIGEST ]] || fail "digest inválido"
  i=$((i + 1))
done

cd "$repo"
[[ -z "$(git status --porcelain)" ]] || fail "el árbol de trabajo no está limpio: el bump necesita un checkout propio"

BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
nc=0
prev_lines=""
new_lines=""
summary_lines=""

# process_set env app tag digest: edita, renderiza y comprueba un patch; hace su commit.
process_set() {
  local env="$1" app="$2" tag="$3" digest="$4"
  local dir="infra/overlays/$env" file p kinds name prev_tag prev_digest last rc got msg
  file="$dir/$app.patch.yaml"
  for p in infra infra/overlays "$dir" "$file"; do
    if [[ -L "$p" ]]; then fail "$p es un enlace simbólico"; fi
  done
  if [[ ! -d "$dir" || ! -e "$file" ]]; then
    if [[ "$env" == prod ]]; then fail "falta $file"; fi
    notice "$env/$app: no hay patch en este ambiente (se quitó el ambiente o la app no lo usa); se omite"
    return 0
  fi
  [[ -f "$file" ]] || fail "$file no es un archivo regular"
  kinds="$(yq e '.kind' "$file" 2>/dev/null)" || fail "$file no es YAML válido"
  [[ "$kinds" == HelmRelease ]] || fail "$file debe ser un solo documento de tipo HelmRelease"
  yq e -e '.spec.values.image | (has("tag") and has("digest"))' "$file" >/dev/null 2>&1 ||
    fail "$file: las claves spec.values.image.tag y spec.values.image.digest deben existir"
  name="$(yq e '.metadata.name' "$file")"
  [[ "$name" =~ $RE_NAME ]] || fail "$file: metadata.name inválido"
  prev_tag="$(yq e '.spec.values.image.tag' "$file")"
  prev_digest="$(yq e '.spec.values.image.digest' "$file")"
  if ((order_guard)); then
    last="$(last_source "$repo" "$env" "$app")"
    if [[ -n "$last" ]]; then
      rc=0
      git merge-base --is-ancestor "$source_sha" "$last" 2>/dev/null || rc=$?
      if ((rc == 0)); then
        warn "$env/$app: según los trailers del historial, el último despliegue ya trae un commit igual o más nuevo; se omite (tras un revert a mano, despliega con un commit nuevo)"
        return 0
      fi
    fi
  fi
  if [[ "$prev_tag" == "$tag" && "$prev_digest" == "$digest" ]]; then
    notice "$env/$app: ya está en $tag; sin cambio"
    return 0
  fi
  TAG="$tag" DIGEST="$digest" yq -i \
    '.spec.values.image.tag = strenv(TAG) | .spec.values.image.tag style="double" | .spec.values.image.digest = strenv(DIGEST)' "$file"
  [[ "$(yq e '.spec.values.image.tag' "$file")" == "$tag" && "$(yq e '.spec.values.image.digest' "$file")" == "$digest" ]] ||
    fail "$file: la edición no dejó el tag y el digest esperados"
  # Render: lo que Flux va a leer debe traer la imagen nueva.
  rc=0
  got="$(kubectl kustomize "$dir" 2>/dev/null | NAME="$name" yq e \
    'select(.kind == "HelmRelease" and .metadata.name == strenv(NAME)) | .spec.values.image.tag + " " + .spec.values.image.digest' - 2>/dev/null)" || rc=$?
  if ((rc != 0)) || [[ "$got" != "$tag $digest" ]]; then
    fail "el overlay $env no renderiza el tag nuevo de $app: no se empuja nada"
  fi
  [[ "$prev_tag" =~ $RE_SHATAG || "$prev_tag" =~ $RE_SEMVER ]] || prev_tag="-"
  [[ "$prev_digest" =~ $RE_DIGEST ]] || prev_digest="-"
  git add -- "$file"
  if [[ -z "$(git diff --cached --name-only)" ]]; then
    warn "$env/$app: la edición no cambió el archivo; se omite"
    return 0
  fi
  [[ "$(git diff --cached --name-only)" == "$file" ]] || fail "el índice trae archivos que no son $file"
  msg="deploy($env): $app -> $tag [skip ci]

Deploy-Env: $env
Deploy-App: $app
Image-Tag: $tag
Image-Digest: $digest
Source-SHA: $source_sha
Previous-Tag: $prev_tag
Previous-Digest: $prev_digest"
  GIT_AUTHOR_NAME="$BOT_NAME" GIT_AUTHOR_EMAIL="$BOT_EMAIL" \
    GIT_COMMITTER_NAME="$BOT_NAME" GIT_COMMITTER_EMAIL="$BOT_EMAIL" \
    git -c "user.name=$BOT_NAME" -c "user.email=$BOT_EMAIL" -c commit.gpgsign=false \
    commit --quiet --no-verify -m "$msg"
  nc=$((nc + 1))
  prev_lines+="$env/$app $prev_digest"$'\n'
  new_lines+="$env/$app $digest"$'\n'
  summary_lines+="| $env | $app | $tag | \`${digest:0:19}…\` |"$'\n'
}

attempt=0
while :; do
  git fetch --quiet --no-tags "$remote" "+refs/heads/main:refs/remotes/$remote/main" ||
    fail "no se pudo leer main del remoto"
  git checkout -q -f -B main "$remote/main"
  nc=0
  prev_lines=""
  new_lines=""
  summary_lines=""
  i=0
  while ((i < nsets)); do
    process_set "${S_ENV[$i]}" "${S_APP[$i]}" "${S_TAG[$i]}" "${S_DIG[$i]}"
    i=$((i + 1))
  done

  if ((nc == 0)); then
    set_output changed false
    set_output commit_sha ""
    printf '' | set_output_multiline previous_digest
    printf '' | set_output_multiline new_digest
    summary "- sin cambios en infra/"
    exit 0
  fi

  if [[ -n "$check_script" ]]; then
    bash "$check_script" ${check_args[@]+"${check_args[@]}"} "$repo" || fail "la verificación de infra/ falló: no se empuja nada"
  fi

  if out="$(git push --porcelain "$remote" "HEAD:refs/heads/main" 2>&1)"; then
    break
  fi
  printf '%s\n' "$out" >&2
  if grep -qiE 'GH013|GH006|protected branch|rule violation' <<<"$out"; then
    fail "main está protegida y el token no puede empujar: configura el secreto push_token (docs/deploy.md, «Rama protegida»)"
  fi
  if grep -qiE 'non-fast-forward|fetch first|\[rejected\]|failed to push' <<<"$out"; then
    attempt=$((attempt + 1))
    if ((attempt > max_retries)); then fail "el push siguió rechazado tras $max_retries reintentos"; fi
    warn "push rechazado por carrera; reintento $attempt de $max_retries sobre la punta fresca"
    continue
  fi
  fail "el push falló"
done

commit_sha="$(git rev-parse HEAD)"
set_output changed true
set_output commit_sha "$commit_sha"
printf '%s' "$prev_lines" | set_output_multiline previous_digest
printf '%s' "$new_lines" | set_output_multiline new_digest
summary "| ambiente | app | tag | digest |"
summary "|---|---|---|---|"
summary "${summary_lines%$'\n'}"
summary ""
summary "commit: \`${commit_sha:0:12}\`"
exit 0
