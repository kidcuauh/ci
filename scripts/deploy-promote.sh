#!/usr/bin/env bash
# Promoción a prod por un Release vX.Y.Z. Uso:
#   deploy-promote.sh --repo DIR --slug OWNER/REPO --owner O --kind push|button|release|hotfix
#                     --source R --version V --apps "a b" [--wait 900] [--interval 30]
#                     [--check-infra SCRIPT [--check-infra-arg ARG]...] [--remote origin]
# La imagen que ya se construyó recibe el tag X.Y.Z (mismo digest, sin reconstruir) y se
# escribe en infra/overlays/prod/. Un X.Y.Z del registro nunca cambia de digest. Si falta
# la imagen de alguna app no se toca prod ni se crea el tag ni el Release. Salidas: las de
# deploy-bump.sh y version. Un X.Y.Z nuevo se reclama (tag y Release) antes de la
# verificación y el push de infra/; si eso falla, el rerun del mismo commit reutiliza el
# Release que quedó sin desplegar en vez de gastar otro número. Documentación: docs/deploy.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/deploy-lib.sh"

repo=""
slug=""
owner=""
kind=""
source_sha=""
version=""
apps=""
wait_s=900
interval=30
remote=origin
pass=()
while (($# > 0)); do
  (($# >= 2)) || fail "argumento sin valor"
  case "$1" in
    --repo) repo="$2" ;;
    --slug) slug="$2" ;;
    --owner) owner="$2" ;;
    --kind) kind="$2" ;;
    --source) source_sha="$2" ;;
    --version) version="$2" ;;
    --apps) apps="$2" ;;
    --wait) wait_s="$2" ;;
    --interval) interval="$2" ;;
    --remote) remote="$2" ;;
    --check-infra) pass+=("$1" "$(abspath "$2")") ;;
    --check-infra-arg) pass+=("$1" "$2") ;;
    *) fail "argumento desconocido" ;;
  esac
  shift 2
done
[[ -d "$repo" ]] || fail "--repo: no es un directorio"
repo="$(cd "$repo" && pwd -P)"
[[ "$slug" =~ $RE_SLUG ]] || fail "--slug inválido"
[[ "$owner" =~ $RE_OWNER ]] || fail "--owner inválido"
case "$kind" in push | button | release | hotfix) ;; *) fail "--kind inválido" ;; esac
[[ "$source_sha" =~ $RE_SHA40 ]] || fail "--source inválido"
if [[ -n "$version" ]]; then [[ "$version" =~ $RE_VERSION ]] || fail "--version inválida"; fi
[[ -n "$apps" ]] || fail "--apps vacío"
for a in $apps; do [[ "$a" =~ $RE_NAME ]] || fail "app inválida"; done
[[ "$remote" =~ $RE_REMOTE ]] || fail "--remote inválido"
for n in "$wait_s" "$interval"; do [[ "$n" =~ ^[0-9]+$ ]] || fail "número inválido"; done

cd "$repo"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mainref="refs/remotes/$remote/main"
reg="$here/deploy-registry.sh"

git fetch --quiet --force --tags "$remote" "+refs/heads/main:$mainref" || fail "no se pudo leer main del remoto"
for app in $apps; do
  git cat-file -e "$mainref:infra/overlays/prod/$app.patch.yaml" 2>/dev/null ||
    fail "falta infra/overlays/prod/$app.patch.yaml en main"
done

lookup() { awk -v a="$2" '$1 == a { print $2 }' "$1"; }

noop() { # mensaje
  notice "$1"
  set_output changed false
  set_output version ""
  summary "- $1"
  exit 0
}

# --- qué se promueve ---------------------------------------------------------
new=0
given=0
ver=""
R=""
case "$kind" in
  push)
    new=1
    R="$source_sha"
    ;;
  button)
    if [[ -z "$version" ]]; then
      new=1
      R="$source_sha"
    else
      ver="$version"
      given=1
      if R="$(git rev-parse -q --verify "refs/tags/$ver^{commit}")"; then
        rc=0
        info="$(bash "$here/deploy-release.sh" info --slug "$slug" --tag "$ver")" || rc=$?
        case "$rc" in
          0)
            read -r draft pre <<<"$info"
            [[ "$draft" == false && "$pre" == false ]] || fail "el Release $ver es un borrador o un pre-release: no se despliega"
            ;;
          3) fail "el tag $ver existe pero no tiene Release: crea el Release primero" ;;
          *) fail "no se pudo consultar el Release $ver" ;;
        esac
      else
        new=1
        R="$source_sha"
        high="$(bash "$here/deploy-version.sh" highest --repo "$repo")"
        if [[ -n "$high" ]] && ! bash "$here/deploy-version.sh" gt "$ver" "$high"; then
          fail "la versión pedida debe ser mayor que la más alta que existe"
        fi
      fi
    fi
    ;;
  release | hotfix)
    [[ -n "$version" ]] || fail "falta la versión del Release"
    ver="$version"
    R="$(git rev-parse -q --verify "refs/tags/$ver^{commit}")" || fail "el tag del Release no está en el checkout"
    [[ "$R" == "$source_sha" ]] || fail "el tag del Release no apunta al commit del evento"
    ;;
esac
semver="${ver#v}"

resolve() { # escribe $work/res
  bash "$here/deploy-resolve.sh" --repo "$repo" --commit "$R" --owner "$owner" --apps "$apps" \
    --wait "$wait_s" --interval "$interval" >"$work/res" || fail "no se encontró la imagen del commit del Release"
  grep -v '^commit ' "$work/res" >"$work/res.apps" || true
}

# --- digests -----------------------------------------------------------------
: >"$work/targets"
if ((new)); then
  resolve
  cp "$work/res.apps" "$work/targets"
else
  : >"$work/have"
  missing=0
  for app in $apps; do
    rc=0
    d="$(bash "$reg" digest "ghcr.io/$owner/$app" "$semver")" || rc=$?
    case "$rc" in
      0) echo "$app $d" >>"$work/have" ;;
      3) missing=1 ;;
      *) fail "no se pudo consultar el registro" ;;
    esac
  done
  have_res=0
  if ((missing)) || [[ "$kind" == release || "$kind" == hotfix ]]; then
    # Un Release nuevo: la imagen del commit manda, y un X.Y.Z que ya exista debe coincidir.
    resolve
    have_res=1
  elif bash "$here/deploy-resolve.sh" --repo "$repo" --commit "$R" --owner "$owner" --apps "$apps" \
    --wait 0 --interval 0 >"$work/res" 2>/dev/null; then
    # El botón con una versión existente: la imagen sha- puede ya no estar (se limpia) o
    # haberse reconstruido; el registro manda, pero una diferencia se avisa.
    grep -v '^commit ' "$work/res" >"$work/res.apps" || true
    have_res=1
  fi
  for app in $apps; do
    h="$(lookup "$work/have" "$app")"
    r=""
    if ((have_res)); then r="$(lookup "$work/res.apps" "$app")"; fi
    if [[ -n "$h" && -n "$r" && "$h" != "$r" ]]; then
      if ((missing)) || [[ "$kind" == release || "$kind" == hotfix ]]; then
        fail "el tag $semver de $app ya existe con otro digest que el del Release: un X.Y.Z nunca se reescribe (registro $h, Release $r)"
      fi
      warn "el tag $semver de $app no coincide con la imagen sha- actual del commit; se despliega el digest del registro"
    fi
    if [[ -n "$h" ]]; then echo "$app $h" >>"$work/targets"; else echo "$app $r" >>"$work/targets"; fi
  done
fi
for app in $apps; do
  [[ "$(lookup "$work/targets" "$app")" =~ $RE_DIGEST ]] || fail "falta el digest de una app"
done

# --- guardas, antes de reclamar nada ------------------------------------------
if [[ "$kind" == push ]]; then
  for app in $apps; do
    last="$(last_source "$repo" prod "$app" "$mainref")"
    if [[ -n "$last" ]] && git merge-base --is-ancestor "$R" "$last" 2>/dev/null; then
      noop "un build igual o más nuevo ya llegó a prod; se salta"
    fi
  done
fi
if [[ "$kind" == push || ("$kind" == button && -z "$version") ]]; then
  same=1
  for app in $apps; do
    cur="$(patch_value "$repo" "$mainref" prod "$app" digest)"
    [[ "$cur" == "$(lookup "$work/targets" "$app")" ]] || same=0
  done
  if ((same)); then noop "esa imagen ya está en prod; no se crea Release"; fi
fi

# --- reutilizar un Release que quedó sin desplegar ----------------------------
# Un run anterior del mismo commit pudo crear el tag y el Release y fallar después (check
# de infra, push rechazado): ese vX.Y.Z existe, apunta a R y prod no lo tiene. Se termina
# ese despliegue en vez de gastar otro número.
reuse=""
if ((new && !given)); then
  best=""
  while IFS= read -r t; do
    [[ "$t" =~ $RE_VERSION ]] || continue
    inprod=1
    for app in $apps; do
      if [[ "$(patch_value "$repo" "$mainref" prod "$app" tag)" != "${t#v}" ||
        "$(patch_value "$repo" "$mainref" prod "$app" digest)" != "$(lookup "$work/targets" "$app")" ]]; then inprod=0; fi
    done
    if ((inprod)); then continue; fi
    rc=0
    info="$(bash "$here/deploy-release.sh" info --slug "$slug" --tag "$t" </dev/null)" || rc=$?
    ((rc == 0)) || continue
    read -r draft pre <<<"$info"
    [[ "$draft" == false && "$pre" == false ]] || continue
    if [[ -z "$best" ]] || bash "$here/deploy-version.sh" gt "$t" "$best"; then best="$t"; fi
  done < <(git tag --points-at "$R" 'v*')
  reuse="$best"
fi

# --- reclamar la versión (solo una nueva) -------------------------------------
if ((new)); then
  n=0
  while :; do
    n=$((n + 1))
    if ((n > 5)); then fail "no se pudo reservar una versión tras 5 intentos"; fi
    if ((given)); then
      ver="$version"
    elif [[ -n "$reuse" ]]; then
      ver="$reuse"
    else
      ver="$(bash "$here/deploy-version.sh" next --repo "$repo")"
    fi
    semver="${ver#v}"
    for app in $apps; do
      rc=0
      d="$(bash "$reg" digest "ghcr.io/$owner/$app" "$semver")" || rc=$?
      case "$rc" in
        0) [[ "$d" == "$(lookup "$work/targets" "$app")" ]] || fail "el tag $semver de $app ya existe con otro digest: no se crea nada" ;;
        3) ;;
        *) fail "no se pudo consultar el registro" ;;
      esac
    done
    if [[ -n "$reuse" ]]; then
      notice "se reutiliza $ver: ya existe su Release, apunta a este commit y prod no lo tiene"
      break
    fi
    rc=0
    bash "$here/deploy-release.sh" create --slug "$slug" --tag "$ver" --sha "$R" || rc=$?
    case "$rc" in
      0) break ;;
      3)
        if ((given)); then fail "la versión $ver ya existe: elige otra"; fi
        git fetch --quiet --force --tags "$remote" || fail "no se pudieron leer los tags"
        ;;
      *) fail "no se pudo crear el Release $ver" ;;
    esac
  done
fi

# --- retag y prod --------------------------------------------------------------
sets=()
for app in $apps; do
  d="$(lookup "$work/targets" "$app")"
  bash "$reg" retag "ghcr.io/$owner/$app" "$d" "$semver"
  sets+=(--set prod "$app" "$semver" "$d")
done
# Un push es automático: además de la guarda de antes de reclamar, la de bump evita que un
# build más viejo pise a uno más nuevo en la punta fresca de main.
guard=()
if [[ "$kind" == push ]]; then guard=(--order-guard); fi
bash "$here/deploy-bump.sh" --repo "$repo" --source "$R" --remote "$remote" ${guard[@]+"${guard[@]}"} "${sets[@]}" ${pass[@]+"${pass[@]}"}
set_output version "$ver"
summary "- versión promovida: \`$ver\`"
