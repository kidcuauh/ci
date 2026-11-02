#!/usr/bin/env bash
# Pruebas sin red de los scripts deploy-*.sh (los de deploy.yml). Usan un docker y un gh
# falsos (scripts/tests/fake-docker y fake-gh-deploy), un origin git local y los ejemplos
# de examples/. Cada escenario tiene su propio origin bare, su clon de trabajo (el
# desarrollador) y un clon "del runner" donde corren los scripts.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
sc="$root/scripts"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ORIG_PATH="$PATH"
PASS=0
FAILED=0

# El git de las pruebas no lee la configuración de quien las corre.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com
export GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com

for tool in git jq yq kubectl shasum sha256sum; do
  if [[ "$tool" == shasum || "$tool" == sha256sum ]]; then continue; fi
  command -v "$tool" >/dev/null || {
    echo "falta $tool en el PATH" >&2
    exit 2
  }
done

result() { # nombre ok(0/1) [detalle]
  if (($2 == 0)); then
    printf 'ok    %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %s%s\n' "$1" "${3:+ ($3)}"
    FAILED=$((FAILED + 1))
  fi
}

# t "nombre" comando args...: ok si el comando sale 0.
t() {
  local name="$1"
  shift
  "$@" >/dev/null 2>&1
  result "$name" $? "$*"
}

h256() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi
}
dig() { printf 'sha256:%s' "$(printf '%s' "$1" | h256)"; }
ZERO="sha256:0000000000000000000000000000000000000000000000000000000000000000"
OWNER=mi-org
HOSTGH=github.com

# --- escenarios ---------------------------------------------------------------
S=""
BASEENV=()
OUT=""
ERR=""
RC=0
SHA=""

gw() { git -C "$S/work" "$@"; }
og() { git --git-dir="$S/origin.git" "$@"; }
ofile() { og show "main:$1"; }
ohead() { og rev-parse refs/heads/main; }

mk() { # nombre ejemplo(minimal|solo-prod)
  S="$tmp/$1"
  rm -rf "$S"
  mkdir -p "$S/reg" "$S/rel" "$S/bin" "$S/home"
  cp "$here/fake-docker/docker" "$S/bin/docker"
  cp "$here/fake-gh-deploy/gh" "$S/bin/gh"
  chmod +x "$S/bin/docker" "$S/bin/gh"
  git init -q --bare -b main "$S/origin.git"
  git clone -q "$S/origin.git" "$S/work" 2>/dev/null
  gw checkout -q -B main
  mkdir -p "$S/work/src"
  echo 0 >"$S/work/src/app.txt"
  cp -R "$root/examples/$2/infra" "$S/work/infra"
  gw add -A
  gw commit -q -m inicial
  gw push -q origin main
  BASEENV=(PATH="$S/bin:$ORIG_PATH" HOME="$S/home" LC_ALL=C
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com
    GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
    FAKE_REGISTRY="$S/reg" FAKE_ORIGIN="$S/origin.git" FAKE_RELEASES="$S/rel"
    FAKE_GH_LOG="$S/gh.log" FAKE_DOCKER_LOG="$S/docker.log" DEPLOY_SLEEP=0)
  : >"$S/gh.log"
  : >"$S/docker.log"
}

sync_work() {
  gw fetch -q origin
  gw reset -q --hard origin/main
}
code() { # [mensaje]: un commit de código en main; deja SHA
  sync_work
  echo "$RANDOM$RANDOM" >>"$S/work/src/app.txt"
  gw add -A
  gw commit -q -m "${1:-codigo}"
  gw push -q origin main
  SHA="$(gw rev-parse HEAD)"
}
infra_only() { # un commit que solo toca infra/ (no un patch de ambiente)
  sync_work
  echo "# $RANDOM" >>"$S/work/infra/base/mi-app/helmrelease.yaml"
  gw add -A
  gw commit -q -m "infra"
  gw push -q origin main
  SHA="$(gw rev-parse HEAD)"
}
add_app() { # nombre: otra app (imagen) en el repo
  local n="$1" d
  sync_work
  cp -R "$S/work/infra/base/mi-app" "$S/work/infra/base/$n"
  grep -rl 'mi-app' "$S/work/infra/base/$n" | while IFS= read -r f; do sed "s/mi-app/$n/g" "$f" >"$f.new" && mv "$f.new" "$f"; done
  for d in "$S"/work/infra/overlays/*/; do
    sed "s/mi-app/$n/g" "${d}mi-app.patch.yaml" >"${d}$n.patch.yaml"
    N="$n" yq -i '.resources += ["../../base/" + strenv(N)] | .patches += [{"path": strenv(N) + ".patch.yaml"}]' "${d}kustomization.yaml"
  done
  gw add -A
  gw commit -q -m "app $n"
  gw push -q origin main
  SHA="$(gw rev-parse HEAD)"
}

reg_put() { # imagen tag digest
  printf '%s' "$3" >"$S/reg/$(printf '%s' "$1:$2" | tr '/:' '__')"
}
reg_get() { # imagen tag
  cat "$S/reg/$(printf '%s' "$1:$2" | tr '/:' '__')" 2>/dev/null || true
}
img() { printf '%s/%s/%s' ghcr.io "$OWNER" "$1"; }
build_img() { # sha apps...: publica sha-<12> de cada app
  local sha="$1" a
  shift
  for a in "$@"; do reg_put "$(img "$a")" "sha-${sha:0:12}" "$(dig "$a$sha")"; done
}
bdig() { dig "$1$2"; } # app sha -> digest que build_img publicó

rr() { # [ref]: un clon fresco del origin, en esa referencia
  rm -rf "$S/runner"
  git clone -q "$S/origin.git" "$S/runner" 2>/dev/null
  git -C "$S/runner" checkout -q --detach "${1:-origin/main}"
}

x() { # VAR=valor... comando args: entorno limpio; deja RC, OUT y ERR
  OUT="$S/out.txt"
  ERR="$S/err.txt"
  : >"$S/gho"
  env -i "${BASEENV[@]}" GITHUB_OUTPUT="$S/gho" "$@" >"$OUT" 2>"$ERR"
  RC=$?
}
ov() { sed -n "s/^$1=//p" "$S/gho" | tail -n 1; }
ovm() { awk -v k="$1" '$0 ~ "^" k "<<" { d = substr($0, length(k) + 3); on = 1; next } on && $0 == d { on = 0 } on { print }' "$S/gho"; }
errhas() { grep -q -- "$1" "$ERR"; }

# --- plan ---------------------------------------------------------------------
echo "== plan"
mk plan minimal
code
P1="$SHA"
plan() { # evento ref sha [VAR=valor...]
  local ev="$1" ref="$2" sha="$3"
  shift 3
  x EVENT_NAME="$ev" GITHUB_REF="$ref" GITHUB_SHA="$sha" REPO_NAME=mi-app OWNER=Mi-Org "$@" bash "$sc/deploy-plan.sh" --repo "$S/runner"
}
rr "$P1"
plan push refs/heads/main "$P1"
t "plan: push con dev -> bump" test "$RC" -eq 0 -a "$(ov mode)" = bump -a "$(ov build)" = true -a "$(ov kind)" = push
t "plan: push con dev -> envs, apps y source" test "$(ov envs)" = dev -a "$(ov apps)" = mi-app -a "$(ov source)" = "$P1"
t "plan: matriz por defecto con el nombre del repo" test "$(ov matrix)" = '[{"name":"mi-app","context":".","dockerfile":"","target":""}]'
plan push refs/heads/otra "$P1"
t "plan: push fuera de main falla" test "$RC" -ne 0
plan pull_request refs/pull/1/merge "$P1"
t "plan: pull_request falla" test "$RC" -ne 0
plan pull_request_target refs/heads/main "$P1"
t "plan: pull_request_target falla" test "$RC" -ne 0
plan push refs/heads/main "no-es-un-sha"
t "plan: GITHUB_SHA inválido falla" test "$RC" -ne 0
# un commit de bump no hace nada
sync_work
gw commit -q --allow-empty -m "deploy(dev): mi-app -> sha-0123456789ab [skip ci]" -m "Deploy-Env: dev"
gw push -q origin main
BUMPC="$(gw rev-parse HEAD)"
rr "$BUMPC"
plan push refs/heads/main "$BUMPC"
t "plan: push de un commit de bump -> none, sin build" test "$RC" -eq 0 -a "$(ov mode)" = none -a "$(ov build)" = false
# sin dev
mk planp solo-prod
code
rr "$SHA"
plan push refs/heads/main "$SHA"
t "plan: push sin dev -> release-auto" test "$RC" -eq 0 -a "$(ov mode)" = release-auto -a "$(ov build)" = true -a -z "$(ov envs)"
# release
mk plan minimal
code
R1="$SHA"
gw tag v1.0.0 "$R1"
gw push -q origin v1.0.0
rr "$R1"
plan release refs/tags/v1.0.0 "$R1" RELEASE_TAG=v1.0.0 RELEASE_PRERELEASE=true
t "plan: pre-release -> none" test "$RC" -eq 0 -a "$(ov mode)" = none -a "$(ov build)" = false
plan release refs/tags/v1.0.0 "$R1" RELEASE_TAG=v1.0 RELEASE_PRERELEASE=false
t "plan: release con tag no semver falla" test "$RC" -ne 0
plan release refs/tags/v1.0.0 "$R1" RELEASE_TAG=v1.0.0 RELEASE_PRERELEASE=false
t "plan: release sobre un commit de main -> promote sin build" test "$RC" -eq 0 -a "$(ov mode)" = promote -a "$(ov build)" = false -a "$(ov kind)" = release -a "$(ov version)" = v1.0.0 -a "$(ov source)" = "$R1"
plan release refs/tags/v1.0.0 "$P1" RELEASE_TAG=v1.0.0 RELEASE_PRERELEASE=false
t "plan: release cuyo tag no es GITHUB_SHA falla" test "$RC" -ne 0
gw checkout -q -b hotfix/x
echo hf >>"$S/work/src/app.txt"
gw add -A
gw commit -q -m hotfix
gw push -q origin hotfix/x
HF="$(gw rev-parse HEAD)"
gw tag v1.0.1 "$HF"
gw push -q origin v1.0.1
gw checkout -q main
rr "$HF"
plan release refs/tags/v1.0.1 "$HF" RELEASE_TAG=v1.0.1 RELEASE_PRERELEASE=false
t "plan: release sobre una rama fuera de main -> promote con build (hotfix)" test "$RC" -eq 0 -a "$(ov mode)" = promote -a "$(ov build)" = true -a "$(ov kind)" = hotfix -a "$(ov source)" = "$HF"
rr "$R1"
plan workflow_dispatch refs/heads/hotfix/x "$R1"
t "plan: botón fuera de main falla" test "$RC" -ne 0
plan workflow_dispatch refs/heads/main "$R1" IN_VERSION=1.0
t "plan: botón con version inválida falla" test "$RC" -ne 0
plan workflow_dispatch refs/heads/main "$R1" 'IN_VERSION=v1.0.0; echo hola'
t "plan: botón con version maliciosa falla" test "$RC" -ne 0
plan workflow_dispatch refs/heads/main "$R1" IN_VERSION=v2.0.0
t "plan: botón con version -> promote sin build" test "$RC" -eq 0 -a "$(ov mode)" = promote -a "$(ov build)" = false -a "$(ov kind)" = button -a "$(ov version)" = v2.0.0
plan workflow_dispatch refs/heads/main "$R1"
t "plan: botón con version vacía" test "$RC" -eq 0 -a "$(ov mode)" = promote -a -z "$(ov version)"
# imágenes
rr "$R1"
plan push refs/heads/main "$R1" REPO_NAME=Mi-App
t "plan: el nombre del repo se pasa a minúsculas" test "$RC" -eq 0 -a "$(ov apps)" = mi-app
plan push refs/heads/main "$R1" REPO_NAME=mi_app
t "plan: nombre de repo que no es DNS-1123 pide images" test "$RC" -ne 0
plan push refs/heads/main "$R1" 'IN_IMAGES=- name: mi-app-api
  context: apps/api
  dockerfile: apps/api/api.Dockerfile
  target: runtime
- name: mi-app-web
  context: apps/web
'
t "plan: monorepo válido" test "$RC" -eq 0 -a "$(ov apps)" = "mi-app-api mi-app-web" -a "$(ov matrix | jq -r '.[0].dockerfile + .[0].target + .[1].context + .[1].target')" = "apps/api/api.Dockerfileruntimeapps/web"
for bad in '- name: mi-app
  extra: x' '- context: apps/api' '- name: Mi_App' '- name: mi-app
  context: ../fuera' '- name: mi-app
  context: /abs' '- name: mi-app
  target: "a b"' '- name: a
- name: a' 'mi-app' '- name: 5' '- name: mi-app
  context: 7' '[]' '{name: mi-app}' '- name: a: b: [' '- name: mi-app
  dockerfile: "a;b"'; do
  plan push refs/heads/main "$R1" "IN_IMAGES=$bad"
  t "plan: images inválido falla ($(printf '%s' "$bad" | head -n 1 | cut -c1-30))" test "$RC" -ne 0
done
big=""
for n in $(seq 1 21); do big+="- name: a$n"$'\n'; done
plan push refs/heads/main "$R1" "IN_IMAGES=$big"
t "plan: más de 20 imágenes falla" test "$RC" -ne 0
# ambientes
rm -rf "$S/runner/infra/overlays/prod"
plan push refs/heads/main "$R1"
t "plan: sin infra/overlays/prod falla" test "$RC" -ne 0
rr "$R1"
mkdir "$S/runner/infra/overlays/Bad_Env"
plan push refs/heads/main "$R1"
t "plan: carpeta de ambiente con nombre inválido falla" test "$RC" -ne 0
rr "$R1"
ln -s dev "$S/runner/infra/overlays/qa"
plan push refs/heads/main "$R1"
t "plan: ambiente que es un enlace simbólico falla" test "$RC" -ne 0
rr "$R1"
touch "$S/runner/infra/overlays/suelto"
plan push refs/heads/main "$R1"
t "plan: archivo suelto en infra/overlays falla" test "$RC" -ne 0
rr "$R1"
cp -R "$S/runner/infra/overlays/dev" "$S/runner/infra/overlays/qa"
plan push refs/heads/main "$R1"
t "plan: varios ambientes ordenados" test "$RC" -eq 0 -a "$(ov envs)" = "dev qa"

# --- version --------------------------------------------------------------------
echo "== version"
mk ver minimal
code
rr "$SHA"
x bash "$sc/deploy-version.sh" next --repo "$S/runner"
t "version: sin tags -> v1.0.0" test "$RC" -eq 0 -a "$(cat "$OUT")" = v1.0.0
for v in v1 v2 v1.2.3 v1.10.0 v01.0.0 v1.2 v1.2.3.4 v1.0.0-rc1 vx; do gw tag "$v" "$SHA"; done
gw push -q origin --tags
rr "$SHA"
x bash "$sc/deploy-version.sh" highest --repo "$S/runner"
t "version: el más alto ignora v1, v2, v1.2, v01.0.0 y orden numérico" test "$(cat "$OUT")" = v1.10.0
x bash "$sc/deploy-version.sh" next --repo "$S/runner"
t "version: v1.10.0 -> v1.10.1" test "$(cat "$OUT")" = v1.10.1
x bash "$sc/deploy-version.sh" gt v2.0.0 v1.10.0
t "version: gt mayor" test "$RC" -eq 0
x bash "$sc/deploy-version.sh" gt v1.2.0 v1.10.0
t "version: gt menor" test "$RC" -eq 1
x bash "$sc/deploy-version.sh" gt v1.0.0 v1.0.0
t "version: gt igual no es mayor" test "$RC" -eq 1
x bash "$sc/deploy-version.sh" gt 1.0.0 v1.0.0
t "version: gt con valor inválido falla" test "$RC" -ne 0

# --- registry -------------------------------------------------------------------
echo "== registry"
reg() { x bash "$sc/deploy-registry.sh" "$@"; }
IM="$(img mi-app)"
D1="$(dig uno)"
D2="$(dig dos)"
reg digest "$IM" sha-0123456789ab
t "registry: tag ausente sale 3" test "$RC" -eq 3
reg_put "$IM" sha-0123456789ab "$D1"
reg digest "$IM" sha-0123456789ab
t "registry: imprime el digest" test "$RC" -eq 0 -a "$(cat "$OUT")" = "$D1"
: >"$S/docker.log"
x FAKE_DOCKER_FAIL=1 bash "$sc/deploy-registry.sh" digest "$IM" sha-0123456789ab
t "registry: un error que no es 'no existe' sale 2 tras 3 intentos" test "$RC" -eq 2 -a "$(grep -c inspect "$S/docker.log")" -eq 3
reg digest "$IM" latest
t "registry: tag inválido sale 2" test "$RC" -eq 2
reg digest "ghcr.io/Mi-Org/x" sha-0123456789ab
t "registry: imagen inválida sale 2" test "$RC" -eq 2
reg retag "$IM" "$D1" 1.0.0
t "registry: retag nuevo" test "$RC" -eq 0 -a "$(reg_get "$IM" 1.0.0)" = "$D1"
: >"$S/docker.log"
reg retag "$IM" "$D1" 1.0.0
t "registry: retag existente con el mismo digest no crea nada" test "$RC" -eq 0 -a "$(grep -c ' create ' "$S/docker.log")" -eq 0
reg retag "$IM" "$D2" 1.0.0
t "registry: retag existente con otro digest falla y no cambia" test "$RC" -ne 0 -a "$(reg_get "$IM" 1.0.0)" = "$D1"
x FAKE_RETAG_DIGEST="$D2" bash "$sc/deploy-registry.sh" retag "$IM" "$D1" 1.0.1
t "registry: retag que no verifica falla" test "$RC" -ne 0
reg retag "$IM" "$D1" v1.0.2
t "registry: retag con tag inválido falla" test "$RC" -ne 0
reg retag "$IM" "sha256:xyz" 1.0.3
t "registry: retag con digest inválido falla" test "$RC" -ne 0

# --- resolve --------------------------------------------------------------------
echo "== resolve"
mk res minimal
res() { # commit apps [args...]
  local c="$1" apps="$2"
  shift 2
  x bash "$sc/deploy-resolve.sh" --repo "$S/runner" --commit "$c" --owner "$OWNER" --apps "$apps" --wait 0 "$@"
}
code
C1="$SHA"
build_img "$C1" mi-app
infra_only
RI="$SHA"
rr "$RI"
res "$RI" mi-app
t "resolve: R de solo infra después del commit construido -> C es el construido" test "$RC" -eq 0 -a "$(sed -n 1p "$OUT")" = "commit $C1" -a "$(sed -n 2p "$OUT")" = "mi-app $(bdig mi-app "$C1")"
code
C2="$SHA"
rr "$C2"
res "$C2" mi-app
t "resolve: código sin imagen falla" test "$RC" -eq 1
t "resolve: el mensaje dice que no se toca prod" errhas "no se toca prod"
build_img "$C2" mi-app
res "$C2" mi-app
t "resolve: R con imagen -> C = R" test "$RC" -eq 0 -a "$(sed -n 1p "$OUT")" = "commit $C2"
x FAKE_DOCKER_FAIL=1 bash "$sc/deploy-resolve.sh" --repo "$S/runner" --commit "$C2" --owner "$OWNER" --apps mi-app --wait 0
t "resolve: un error del registro falla en el acto" test "$RC" -eq 1
# monorepo: todo o nada
add_app mi-app-web
code
M1="$SHA"
build_img "$M1" mi-app
rr "$M1"
res "$M1" "mi-app mi-app-web"
t "resolve: monorepo con una app sin imagen falla" test "$RC" -eq 1
build_img "$M1" mi-app-web
res "$M1" "mi-app mi-app-web"
t "resolve: monorepo con todas las apps" test "$RC" -eq 0 -a "$(grep -c . "$OUT")" -eq 3
code
M2="$SHA"
build_img "$M2" mi-app
rr "$M2"
res "$M2" "mi-app mi-app-web"
t "resolve: una app solo con imagen vieja no se mezcla con commits distintos" test "$RC" -eq 1
# más de 20 commits de solo infra
mk res2 minimal
code
B0="$SHA"
build_img "$B0" mi-app
for _ in $(seq 1 19); do infra_only; done
rr "$SHA"
res "$SHA" mi-app
t "resolve: 19 commits de infra aún alcanzan (20 candidatos)" test "$RC" -eq 0
infra_only
rr "$SHA"
res "$SHA" mi-app
t "resolve: más de 20 commits de solo infra falla" test "$RC" -eq 1
res "$SHA" mi-app --max-commits 50
t "resolve: --max-commits lo amplía" test "$RC" -eq 0
# espera
mk res3 minimal
code
W1="$SHA"
rr "$W1"
(
  sleep 1
  build_img "$W1" mi-app
) &
bgpid=$!
x bash "$sc/deploy-resolve.sh" --repo "$S/runner" --commit "$W1" --owner "$OWNER" --apps mi-app --wait 10 --interval 1
wait "$bgpid"
t "resolve: espera a que aparezca la imagen" test "$RC" -eq 0

# --- bump -----------------------------------------------------------------------
echo "== bump"
mk bump minimal
code
B1="$SHA"
code
B2="$SHA"
code
B3="$SHA"
DEVPATCH=infra/overlays/dev/mi-app.patch.yaml
PRODPATCH=infra/overlays/prod/mi-app.patch.yaml
T2="sha-${B2:0:12}"
DB2="$(bdig mi-app "$B2")"
PROD_BEFORE="$(ofile "$PRODPATCH")"
HEAD_BEFORE="$(ohead)"
rr
bump() { # args de deploy-bump.sh (después de --repo y --source)
  x bash "$sc/deploy-bump.sh" --repo "$S/runner" "$@"
}
bump --source "$B2" --set dev mi-app "$T2" "$DB2"
t "bump: sale 0 y changed=true" test "$RC" -eq 0 -a "$(ov changed)" = true
t "bump: un solo commit nuevo y es la punta del origin" test "$(og rev-list --count "$HEAD_BEFORE..main")" -eq 1 -a "$(ov commit_sha)" = "$(ohead)"
EXPECTED="deploy(dev): mi-app -> $T2 [skip ci]

Deploy-Env: dev
Deploy-App: mi-app
Image-Tag: $T2
Image-Digest: $DB2
Source-SHA: $B2
Previous-Tag: sha-0123456789ab
Previous-Digest: $ZERO"
t "bump: asunto y trailers exactos" test "$(og log -1 --format=%B main)" = "$EXPECTED"
t "bump: autor y committer son el bot" test "$(og log -1 --format='%an <%ae> | %cn <%ce>' main)" = 'github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com> | github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
t "bump: el commit toca solo el patch de dev" test "$(og show --name-only --format= main)" = "$DEVPATCH"
t "bump: el tag queda entre comillas dobles" grep -q "tag: \"$T2\"" <(ofile "$DEVPATCH")
t "bump: el digest queda en el archivo" grep -q "digest: $DB2" <(ofile "$DEVPATCH")
t "bump: el diff cambia solo dos líneas" test "$(og diff --numstat "$HEAD_BEFORE" main | awk '{print $1 "+" $2}')" = "2+2"
t "bump: prod intacto" test "$(ofile "$PRODPATCH")" = "$PROD_BEFORE"
t "bump: previous_digest y new_digest" test "$(ovm previous_digest)" = "dev/mi-app $ZERO" -a "$(ovm new_digest)" = "dev/mi-app $DB2"
HEAD1="$(ohead)"
rr
bump --source "$B2" --set dev mi-app "$T2" "$DB2"
t "bump: repetir el mismo SHA no hace otro commit" test "$RC" -eq 0 -a "$(ov changed)" = false -a "$(ohead)" = "$HEAD1"
rr
bump --source "$B2" --order-guard --set dev mi-app "$T2" "$DB2"
t "bump: repetir el mismo SHA con guarda de orden tampoco" test "$RC" -eq 0 -a "$(ov changed)" = false -a "$(ohead)" = "$HEAD1"
# guarda de orden
T1="sha-${B1:0:12}"
rr
bump --source "$B1" --order-guard --set dev mi-app "$T1" "$(bdig mi-app "$B1")"
t "bump: un source más viejo que el último bump se omite" test "$RC" -eq 0 -a "$(ov changed)" = false -a "$(ohead)" = "$HEAD1"
t "bump: la omisión avisa" errhas "se omite"
T3="sha-${B3:0:12}"
rr
bump --source "$B3" --order-guard --set dev mi-app "$T3" "$(bdig mi-app "$B3")"
t "bump: un source más nuevo avanza" test "$RC" -eq 0 -a "$(ov changed)" = true
rr
bump --source "$B1" --set dev mi-app "$T1" "$(bdig mi-app "$B1")"
t "bump: sin guarda de orden (rollback) retrocede" test "$RC" -eq 0 -a "$(ov changed)" = true
# ambiente o app sin patch
rr
bump --source "$B2" --set qa mi-app "$T2" "$DB2"
t "bump: un ambiente que no es prod sin carpeta se omite con aviso" test "$RC" -eq 0 -a "$(ov changed)" = false
rr
bump --source "$B2" --set prod nope 1.0.0 "$DB2"
t "bump: prod sin patch falla" test "$RC" -ne 0
# entradas maliciosas
rr
HB="$(ohead)"
rm -f "$S/pwned"
bump --source "$B2" --set dev mi-app "sha-0123456789ab\$(touch $S/pwned)" "$DB2"
t "bump: tag con \$() se rechaza y no se ejecuta" test "$RC" -ne 0 -a ! -e "$S/pwned" -a "$(ohead)" = "$HB"
bump --source "$B2" --set dev mi-app "$T2" "$(printf '%s\nfoo' "$DB2")"
t "bump: digest con salto de línea se rechaza" test "$RC" -ne 0
bump --source "$B2" --set 'dev;x' mi-app "$T2" "$DB2"
t "bump: ambiente malicioso se rechaza" test "$RC" -ne 0
bump --source "$B2" --set dev '../mi-app' "$T2" "$DB2"
t "bump: app con .. se rechaza" test "$RC" -ne 0
bump --source "$B2" --set dev mi-app "1.0.0" "$DB2"
t "bump: un semver en un ambiente que no es prod se rechaza" test "$RC" -ne 0
bump --source "$B2" --set prod mi-app "$T2" "$DB2"
t "bump: un sha- en prod se rechaza" test "$RC" -ne 0
bump --source "xyz" --set dev mi-app "$T2" "$DB2"
t "bump: source inválido se rechaza" test "$RC" -ne 0
bump --source "$B2" --remote '-x' --set dev mi-app "$T2" "$DB2"
t "bump: remote inválido se rechaza" test "$RC" -ne 0
# árbol sucio
rr
echo x >"$S/runner/suelto.txt"
bump --source "$B3" --set dev mi-app "$T3" "$(bdig mi-app "$B3")"
t "bump: árbol sucio falla" test "$RC" -ne 0
t "bump: árbol sucio explica por qué" errhas "limpio"
# carrera: un pre-push que empuja otro commit al origin la primera vez
mk race minimal
code
code
R_2="$SHA"
rr
cat >"$S/runner/.git/hooks/pre-push" <<HOOK
#!/bin/sh
[ -e "$S/hookdone" ] && exit 0
: > "$S/hookdone"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
git -C "$S/work" fetch -q origin
git -C "$S/work" reset -q --hard origin/main
echo carrera >> "$S/work/src/app.txt"
git -C "$S/work" add -A
git -C "$S/work" commit -q -m carrera
git -C "$S/work" push -q origin main
HOOK
chmod +x "$S/runner/.git/hooks/pre-push"
bump --source "$R_2" --set dev mi-app "sha-${R_2:0:12}" "$(bdig mi-app "$R_2")"
t "bump: una carrera reintenta y termina bien" test "$RC" -eq 0 -a "$(ov changed)" = true
t "bump: la carrera avisa del reintento" errhas "reintento 1 de 5"
t "bump: historial lineal con el commit de la carrera debajo del bump" test "$(og rev-list --merges main | wc -l | tr -d ' ')" -eq 0 -a "$(og log -2 --format=%s main | tail -n 1)" = carrera
# rama protegida
mk prot minimal
code
PR1="$SHA"
cat >"$S/origin.git/hooks/pre-receive" <<HOOK
#!/bin/sh
echo x >> "$S/pushes"
echo "remote: error: GH013: Repository rule violations found for refs/heads/main." >&2
exit 1
HOOK
chmod +x "$S/origin.git/hooks/pre-receive"
rr
HB="$(ohead)"
bump --source "$PR1" --set dev mi-app "sha-${PR1:0:12}" "$(bdig mi-app "$PR1")"
t "bump: rama protegida falla" test "$RC" -ne 0 -a "$(ohead)" = "$HB"
t "bump: rama protegida remite a push_token" errhas "push_token"
t "bump: rama protegida no reintenta" test "$(wc -l <"$S/pushes" | tr -d ' ')" -eq 1
# el overlay no renderiza el tag nuevo
mk render minimal
sync_work
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - ../../base/mi-app\n' >"$S/work/infra/overlays/dev/kustomization.yaml"
gw add -A
gw commit -q -m "dev sin patch"
gw push -q origin main
code
RN="$SHA"
rr
HB="$(ohead)"
bump --source "$RN" --set dev mi-app "sha-${RN:0:12}" "$(bdig mi-app "$RN")"
t "bump: un overlay que no renderiza el tag nuevo falla sin empujar" test "$RC" -ne 0 -a "$(ohead)" = "$HB"
t "bump: el mensaje dice que no renderiza" errhas "no renderiza"
# claves ausentes
mk keys minimal
sync_work
yq -i 'del(.spec.values.image.digest)' "$S/work/$DEVPATCH"
gw add -A
gw commit -q -m "sin digest"
gw push -q origin main
code
KS="$SHA"
rr
HB="$(ohead)"
bump --source "$KS" --set dev mi-app "sha-${KS:0:12}" "$(bdig mi-app "$KS")"
t "bump: una clave ausente falla sin empujar" test "$RC" -ne 0 -a "$(ohead)" = "$HB"
t "bump: el mensaje dice que la clave debe existir" errhas "deben existir"
# enlace simbólico
mk link minimal
sync_work
rm "$S/work/$DEVPATCH"
ln -s mi-app.patch.yaml "$S/work/infra/overlays/dev/real.yaml"
mv "$S/work/infra/overlays/dev/real.yaml" "$S/work/$DEVPATCH"
gw add -A
gw commit -q -m "patch como enlace"
gw push -q origin main
code
LK="$SHA"
rr
HB="$(ohead)"
bump --source "$LK" --set dev mi-app "sha-${LK:0:12}" "$(bdig mi-app "$LK")"
t "bump: un patch que es enlace simbólico falla" test "$RC" -ne 0 -a "$(ohead)" = "$HB"
# check-infra
mk chk minimal
code
CK="$SHA"
rr
HB="$(ohead)"
printf '#!/bin/sh\necho "$@" > "%s/chk.args"\nexit 1\n' "$S" >"$S/chk-fail.sh"
bump --source "$CK" --set dev mi-app "sha-${CK:0:12}" "$(bdig mi-app "$CK")" --check-infra "$S/chk-fail.sh" --check-infra-arg --uno --check-infra-arg dos
t "bump: un check-infra que falla no empuja" test "$RC" -ne 0 -a "$(ohead)" = "$HB"
t "bump: check-infra recibe sus argumentos y la ruta del repo" test "$(cat "$S/chk.args")" = "--uno dos $(cd "$S/runner" && pwd -P)"
rr
printf '#!/bin/sh\nexit 0\n' >"$S/chk-ok.sh"
bump --source "$CK" --set dev mi-app "sha-${CK:0:12}" "$(bdig mi-app "$CK")" --check-infra "$S/chk-ok.sh"
t "bump: con check-infra en verde empuja" test "$RC" -eq 0 -a "$(ov changed)" = true
# la ruta de check-infra relativa al directorio de quien llama (como ci/scripts/... en el workspace)
mk chkrel minimal
code
CR="$SHA"
rr
printf '#!/bin/sh\ntouch "%s/chk.ran"\nexit 0\n' "$S" >"$S/chk-rel.sh"
pushd "$S" >/dev/null || exit 2
bump --source "$CR" --set dev mi-app "sha-${CR:0:12}" "$(bdig mi-app "$CR")" --check-infra chk-rel.sh
popd >/dev/null || exit 2
t "bump: --check-infra relativo al cwd de quien llama sigue valiendo tras el cd al repo" test "$RC" -eq 0 -a -f "$S/chk.ran" -a "$(ov changed)" = true
# varios en un push
mk multi minimal
add_app mi-app-web
code
MU="$SHA"
rr
HB="$(ohead)"
bump --source "$MU" --set dev mi-app "sha-${MU:0:12}" "$(bdig mi-app "$MU")" --set dev mi-app-web "sha-${MU:0:12}" "$(bdig mi-app-web "$MU")"
t "bump: dos apps -> dos commits en un solo push" test "$RC" -eq 0 -a "$(og rev-list --count "$HB..main")" -eq 2 -a "$(ovm new_digest | wc -l | tr -d ' ')" -eq 2

# --- git_auth -------------------------------------------------------------------
echo "== git_auth"
mk auth minimal
rr
ga() { # VAR=valor...: corre git_auth en un shell limpio y muestra el entorno resultante
  # shellcheck disable=SC2016 # el script entre comillas simples se expande en el bash de adentro
  x RUNNER_TEMP="$S/rt" "$@" bash -c 'source "$1"; git_auth "$2" mi-org/mi-app; echo "CV=${GIT_CONFIG_VALUE_0:-}"; echo "SSH=${GIT_SSH_COMMAND:-}"' _ "$sc/deploy-lib.sh" "$S/runner"
}
mkdir -p "$S/rt"
ga
t "git_auth: sin tokens no hace nada" test "$RC" -eq 0 -a "$(grep -c '^CV=$' "$OUT")" -eq 1
ga DEPLOY_READ_TOKEN=lectura
B64="$(printf 'x-access-token:lectura' | base64 | tr -d '\n')"
t "git_auth: token de lectura -> cabecera basic" grep -qx "CV=AUTHORIZATION: basic $B64" "$OUT"
t "git_auth: enmascara el valor antes de exportarlo" grep -qx "::add-mask::$B64" "$OUT"
ga DEPLOY_READ_TOKEN=lectura DEPLOY_PUSH_TOKEN=escritura
B64="$(printf 'x-access-token:escritura' | base64 | tr -d '\n')"
t "git_auth: push_token HTTPS reemplaza al de lectura" grep -qx "CV=AUTHORIZATION: basic $B64" "$OUT"
t "git_auth: ningún token queda en .git/config" test -z "$(grep -ril 'lectura\|escritura' "$S/runner/.git/config")"
ga DEPLOY_READ_TOKEN=lectura "DEPLOY_PUSH_TOKEN=-----BEGIN OPENSSH PRIVATE KEY-----
abc
-----END OPENSSH PRIVATE KEY-----"
B64="$(printf 'x-access-token:lectura' | base64 | tr -d '\n')"
t "git_auth: una llave SSH se usa para empujar y el token de lectura para leer" grep -qx "CV=AUTHORIZATION: basic $B64" "$OUT"
t "git_auth: la llave queda con permisos 600" test -n "$(find "$S/rt/deploy-key" -perm 600)"
t "git_auth: GIT_SSH_COMMAND con host key estricta" grep -q 'SSH=ssh -i .*StrictHostKeyChecking=yes' "$OUT"
t "git_auth: la URL de push pasa a SSH" test "$(git -C "$S/runner" config remote.origin.pushurl)" = "git@${HOSTGH}:mi-org/mi-app.git"
t "git_auth: known_hosts trae ed25519 y ecdsa, sin RSA" test "$(grep -c 'ssh-ed25519\|ecdsa-sha2' "$S/rt/deploy-known-hosts")" -eq 2 -a "$(grep -c ssh-rsa "$S/rt/deploy-known-hosts")" -eq 0

# --- nonprod ----------------------------------------------------------------------
echo "== nonprod"
mk np minimal
cp -R "$S/work/infra/overlays/dev" "$S/work/infra/overlays/qa"
gw add -A
gw commit -q -m "qa"
gw push -q origin main
code
N1="$SHA"
rr
np() { x bash "$sc/deploy-nonprod.sh" --repo "$S/runner" --source "$N1" --owner "$OWNER" --apps "${APPS:-mi-app}" --envs "${ENVS:-dev qa}"; }
HB="$(ohead)"
np
t "nonprod: sin la imagen publicada falla y no toca nada" test "$RC" -ne 0 -a "$(ohead)" = "$HB"
build_img "$N1" mi-app
rr
np
t "nonprod: bump a todos los ambientes con el sha- y el digest" test "$RC" -eq 0 -a "$(og rev-list --count "$HB..main")" -eq 2 -a "$(ofile infra/overlays/qa/mi-app.patch.yaml | yq e .spec.values.image.digest -)" = "$(bdig mi-app "$N1")"
t "nonprod: prod intacto" test "$(ofile "$PRODPATCH" | yq e .spec.values.image.tag -)" = 1.0.0
t "nonprod: Source-SHA es el commit construido" test "$(og log -1 --format=%B main | sed -n 's/^Source-SHA: //p')" = "$N1"

# --- promote --------------------------------------------------------------------
echo "== promote"
prom() { # kind source version [args...]
  local kind="$1" src="$2" ver="$3"
  shift 3
  x bash "$sc/deploy-promote.sh" --repo "$S/runner" --slug "$OWNER/mi-app" --owner "$OWNER" --kind "$kind" --source "$src" --version "$ver" --apps "${APPS:-mi-app}" --wait 0 --interval 0 "$@"
}
prod_digest() { ofile "infra/overlays/prod/${1:-mi-app}.patch.yaml" | yq e .spec.values.image.digest -; }
prod_tag() { ofile "infra/overlays/prod/${1:-mi-app}.patch.yaml" | yq e .spec.values.image.tag -; }
rels() { find "$S/rel" -maxdepth 1 -type f -name 'v*' | wc -l | tr -d ' '; }
tagsn() { og tag -l 'v*' | wc -l | tr -d ' '; }

# Sin dev: cada merge crea su Release.
mk pr solo-prod
code
Q1="$SHA"
build_img "$Q1" mi-app
rr "$Q1"
prom push "$Q1" ""
t "promote: Release automático sin dev crea v1.0.0" test "$RC" -eq 0 -a "$(ov version)" = v1.0.0 -a "$(og rev-parse refs/tags/v1.0.0)" = "$Q1" -a -f "$S/rel/v1.0.0"
t "promote: retag 1.0.0 con el mismo digest, sin reconstruir" test "$(reg_get "$(img mi-app)" 1.0.0)" = "$(bdig mi-app "$Q1")"
t "promote: prod escrito con tag y digest" test "$(prod_tag)" = 1.0.0 -a "$(prod_digest)" = "$(bdig mi-app "$Q1")"
PRODMSG="$(og log -1 --format=%B main)"
t "promote: trailers de prod con Source-SHA = R" test "$(sed -n 's/^Source-SHA: //p' <<<"$PRODMSG")" = "$Q1" -a "$(sed -n 's/^Deploy-Env: //p' <<<"$PRODMSG")" = prod -a "$(sed -n 's/^Image-Tag: //p' <<<"$PRODMSG")" = 1.0.0
t "promote: no se crea el Release con un token que dispare otro run (un solo Release creado)" test "$(grep -c 'POST repos/.*/releases' "$S/gh.log")" -eq 1
code
Q2="$SHA"
build_img "$Q2" mi-app
rr "$Q2"
prom push "$Q2" ""
t "promote: el segundo Release es v1.0.1" test "$RC" -eq 0 -a "$(ov version)" = v1.0.1 -a "$(prod_tag)" = 1.0.1
NT="$(tagsn)"
NR="$(rels)"
HP="$(ohead)"
rr "$Q1"
prom push "$Q1" ""
t "promote: un build más viejo que el de prod se salta sin Release" test "$RC" -eq 0 -a "$(ov changed)" = false -a "$(tagsn)" = "$NT" -a "$(rels)" = "$NR" -a "$(ohead)" = "$HP"
t "promote: el salto avisa" errhas "más nuevo"
rr "$Q2"
prom push "$Q2" ""
t "promote: el mismo SHA otra vez no crea nada" test "$RC" -eq 0 -a "$(ov changed)" = false -a "$(tagsn)" = "$NT" -a "$(ohead)" = "$HP"
# el botón vacío con la imagen ya en prod
rr "$HP"
prom button "$HP" ""
t "promote: botón vacío con la imagen ya en prod no crea Release ni commit" test "$RC" -eq 0 -a "$(ov changed)" = false -a "$(tagsn)" = "$NT" -a "$(rels)" = "$NR" -a "$(ohead)" = "$HP"
# versión nueva con número dado
code
Q3="$SHA"
build_img "$Q3" mi-app
rr "$Q3"
prom button "$Q3" v2.0.0
t "promote: botón con vX.Y.Z nuevo usa ese número" test "$RC" -eq 0 -a "$(ov version)" = v2.0.0 -a "$(prod_tag)" = 2.0.0 -a "$(prod_digest)" = "$(bdig mi-app "$Q3")"
code
Q4="$SHA"
build_img "$Q4" mi-app
rr "$Q4"
NT="$(tagsn)"
prom button "$Q4" v1.5.0
t "promote: botón con una versión menor que la más alta y nueva falla" test "$RC" -ne 0 -a "$(tagsn)" = "$NT"
# rollback
rr
HP="$(ohead)"
prom button "$HP" v1.0.1
t "promote: rollback con el botón y una versión existente" test "$RC" -eq 0 -a "$(prod_tag)" = 1.0.1 -a "$(prod_digest)" = "$(bdig mi-app "$Q2")"
RBMSG="$(og log -1 --format=%B main)"
t "promote: el rollback deja Previous-* en un solo commit" test "$(sed -n 's/^Previous-Tag: //p' <<<"$RBMSG")" = 2.0.0 -a "$(sed -n 's/^Previous-Digest: //p' <<<"$RBMSG")" = "$(bdig mi-app "$Q3")" -a "$(sed -n 's/^Source-SHA: //p' <<<"$RBMSG")" = "$Q2"
t "promote: el rollback no crea Release ni tag" test "$(tagsn)" = "$NT"
# rollback con las imágenes sha- ya limpiadas
rm -f "$S"/reg/*__sha-*
rr
prom button "$(ohead)" v2.0.0
t "promote: volver a una versión funciona aunque el sha- ya se limpió" test "$RC" -eq 0 -a "$(prod_tag)" = 2.0.0
# versión existente sin Release
gw fetch -q origin
gw tag v3.0.0 "$Q3"
gw push -q origin v3.0.0
rr
prom button "$(ohead)" v3.0.0
t "promote: una versión existente sin Release falla" test "$RC" -ne 0
t "promote: lo dice" errhas "no tiene Release"
printf '{"draft":true,"prerelease":false}\n' >"$S/rel/v3.0.0"
prom button "$(ohead)" v3.0.0
t "promote: un Release en borrador falla" test "$RC" -ne 0
# Release a mano
code
Q5="$SHA"
build_img "$Q5" mi-app
gw tag v3.1.0 "$Q5"
gw push -q origin v3.1.0
printf '{"draft":false,"prerelease":false}\n' >"$S/rel/v3.1.0"
: >"$S/gh.log"
rr "$Q5"
prom release "$Q5" v3.1.0
t "promote: un Release a mano promueve sin crear otro Release" test "$RC" -eq 0 -a "$(prod_tag)" = 3.1.0 -a "$(prod_digest)" = "$(bdig mi-app "$Q5")" -a "$(grep -c 'POST repos/.*/releases' "$S/gh.log")" -eq 0
t "promote: Source-SHA del Release a mano = su commit" test "$(og log -1 --format=%B main | sed -n 's/^Source-SHA: //p')" = "$Q5"
rr "$Q5"
prom release "$Q4" v3.1.0
t "promote: release cuyo tag no es el commit del evento falla" test "$RC" -ne 0
# choque al crear el tag
code
Q6="$SHA"
build_img "$Q6" mi-app
rr "$Q6"
rm -f "$S/rel/.collided"
x FAKE_GH_COLLIDE_TAG=v3.1.1 bash "$sc/deploy-promote.sh" --repo "$S/runner" --slug "$OWNER/mi-app" --owner "$OWNER" --kind push --source "$Q6" --version "" --apps mi-app --wait 0 --interval 0
t "promote: un choque al crear el tag pasa al siguiente número" test "$RC" -eq 0 -a "$(ov version)" = v3.1.2 -a "$(prod_tag)" = 3.1.2
# falla al crear el Release
code
Q7="$SHA"
build_img "$Q7" mi-app
rr "$Q7"
HP="$(ohead)"
x FAKE_GH_RELEASE_FAIL=1 bash "$sc/deploy-promote.sh" --repo "$S/runner" --slug "$OWNER/mi-app" --owner "$OWNER" --kind push --source "$Q7" --version "" --apps mi-app --wait 0 --interval 0
t "promote: si falla el Release no se toca prod" test "$RC" -ne 0 -a "$(ohead)" = "$HP" -a "$(prod_digest)" != "$(bdig mi-app "$Q7")"
t "promote: dice cómo seguir" errhas "a mano"
t "promote: ni siquiera se hace el retag" test -z "$(reg_get "$(img mi-app)" 3.1.3)"
# imagen ausente
code
Q8="$SHA"
rr "$Q8"
HP="$(ohead)"
NT="$(tagsn)"
NR="$(rels)"
prom push "$Q8" ""
t "promote: sin imagen falla sin tag, sin Release y sin commit" test "$RC" -ne 0 -a "$(tagsn)" = "$NT" -a "$(rels)" = "$NR" -a "$(ohead)" = "$HP"
t "promote: dice que no tiene imagen" errhas "no tiene imagen"
# X.Y.Z del registro con otro digest
code
Q9="$SHA"
build_img "$Q9" mi-app
rr "$Q9"
NEXT="$(bash "$sc/deploy-version.sh" next --repo "$S/runner")"
reg_put "$(img mi-app)" "${NEXT#v}" "$(dig ajeno)"
NT="$(tagsn)"
NR="$(rels)"
HP="$(ohead)"
prom push "$Q9" ""
t "promote: un X.Y.Z del registro con otro digest falla antes de crear nada" test "$RC" -ne 0 -a "$(tagsn)" = "$NT" -a "$(rels)" = "$NR" -a "$(ohead)" = "$HP" -a "$(reg_get "$(img mi-app)" "${NEXT#v}")" = "$(dig ajeno)"
rm -f "$S/reg/$(printf '%s' "$(img mi-app):${NEXT#v}" | tr '/:' '__')"
# retag que no verifica
rr "$Q9"
x FAKE_RETAG_DIGEST="$(dig otro)" bash "$sc/deploy-promote.sh" --repo "$S/runner" --slug "$OWNER/mi-app" --owner "$OWNER" --kind push --source "$Q9" --version "" --apps mi-app --wait 0 --interval 0
t "promote: un retag que no verifica no escribe prod" test "$RC" -ne 0 -a "$(ohead)" = "$HP"
# prod sin patch de la app
rr "$Q9"
prom push "$Q9" "" --apps "mi-app nope"
t "promote: una app sin patch en prod falla" test "$RC" -ne 0
# monorepo: todo o nada
mk mono solo-prod
add_app mi-app-web
code
O1="$SHA"
build_img "$O1" mi-app
rr "$O1"
HP="$(ohead)"
APPS="mi-app mi-app-web" prom push "$O1" ""
t "promote: monorepo con una imagen faltante no crea nada" test "$RC" -ne 0 -a "$(tagsn)" = 0 -a "$(ohead)" = "$HP"
build_img "$O1" mi-app-web
rr "$O1"
APPS="mi-app mi-app-web" prom push "$O1" ""
t "promote: monorepo con todas las imágenes promueve ambas en un push" test "$RC" -eq 0 -a "$(prod_tag mi-app)" = 1.0.0 -a "$(prod_tag mi-app-web)" = 1.0.0 -a "$(og rev-list --count "$HP..main")" -eq 2
t "promote: monorepo retag de cada app con su digest" test "$(reg_get "$(img mi-app-web)" 1.0.0)" = "$(bdig mi-app-web "$O1")"
# un Release existente al que le falta el X.Y.Z de una app: se resuelve y debe coincidir
HP="$(ohead)"
reg_put "$(img mi-app)" 1.0.0 "$(dig distinto)"
rm -f "$S/reg/$(printf '%s' "$(img mi-app-web):1.0.0" | tr '/:' '__')"
rr
APPS="mi-app mi-app-web" prom button "$(ohead)" v1.0.0
t "promote: un X.Y.Z que difiere del digest resuelto del Release no se despliega" test "$RC" -ne 0 -a "$(ohead)" = "$HP" -a -z "$(reg_get "$(img mi-app-web)" 1.0.0)"
reg_put "$(img mi-app)" 1.0.0 "$(bdig mi-app "$O1")"
rr
APPS="mi-app mi-app-web" prom button "$(ohead)" v1.0.0
t "promote: a un Release existente le faltaba una app: se resuelve y se retaguea solo esa" test "$RC" -eq 0 -a "$(reg_get "$(img mi-app-web)" 1.0.0)" = "$(bdig mi-app-web "$O1")"

# Un fallo después de reclamar la versión no gasta otra en el rerun
mk orf solo-prod
code
OR1="$SHA"
build_img "$OR1" mi-app
rr "$OR1"
printf '#!/bin/sh\nexit 1\n' >"$S/chk-fail.sh"
printf '#!/bin/sh\ntouch "%s/chk.ran"\nexit 0\n' "$S" >"$S/chk-ok.sh"
HP="$(ohead)"
prom push "$OR1" "" --check-infra "$S/chk-fail.sh"
t "promote: un check-infra rojo falla sin tocar prod y deja el Release sin desplegar" test "$RC" -ne 0 -a "$(ohead)" = "$HP" -a "$(tagsn)" = 1 -a "$(rels)" = 1
rr "$OR1"
pushd "$S" >/dev/null || exit 2
prom push "$OR1" "" --check-infra chk-ok.sh
popd >/dev/null || exit 2
t "promote: el rerun reutiliza ese Release (no gasta otro número) y --check-infra relativo vale" test "$RC" -eq 0 -a "$(ov version)" = v1.0.0 -a "$(tagsn)" = 1 -a "$(rels)" = 1 -a "$(prod_digest)" = "$(bdig mi-app "$OR1")" -a -f "$S/chk.ran"
# Release nuevo con un X.Y.Z del registro con otro digest que la imagen del commit
mk stl solo-prod
code
ST="$SHA"
build_img "$ST" mi-app
gw tag v9.0.0 "$ST"
gw push -q origin v9.0.0
printf '{"draft":false,"prerelease":false}\n' >"$S/rel/v9.0.0"
reg_put "$(img mi-app)" 9.0.0 "$(dig viejo)"
rr "$ST"
HP="$(ohead)"
prom release "$ST" v9.0.0
t "promote: un Release nuevo con un X.Y.Z del registro de otro digest falla y no toca prod" test "$RC" -ne 0 -a "$(ohead)" = "$HP"
t "promote: dice que el X.Y.Z ya existe con otro digest" errhas "otro digest"
# El botón con una versión existente: el registro manda aunque sha- se haya reconstruido
mk btn solo-prod
code
BT="$SHA"
build_img "$BT" mi-app
rr "$BT"
prom push "$BT" ""
BTD="$(bdig mi-app "$BT")"
reg_put "$(img mi-app)" "sha-${BT:0:12}" "$(dig reconstruida)"
rr
prom button "$(ohead)" v1.0.0
t "promote: el botón con versión existente usa el digest del registro y avisa si sha- cambió" test "$RC" -eq 0 -a "$(prod_digest)" = "$BTD"
t "promote: el aviso de diferencia sale" errhas "no coincide"

# Con dev: el botón promueve, el hotfix construye.
mk pd minimal
code
D1="$SHA"
build_img "$D1" mi-app
rr "$D1"
x bash "$sc/deploy-nonprod.sh" --repo "$S/runner" --source "$D1" --owner "$OWNER" --apps mi-app --envs dev
DEVBUMP="$(ohead)"
DEVFILE_AFTER_DEV="$(ofile "$DEVPATCH")"
rr "$DEVBUMP"
prom button "$DEVBUMP" ""
t "promote: botón vacío resuelve por primer padre aunque HEAD sea un bump" test "$RC" -eq 0 -a "$(ov version)" = v1.0.0 -a "$(prod_digest)" = "$(bdig mi-app "$D1")"
t "promote: Source-SHA en prod es el commit del Release (R)" test "$(og log -1 --format=%B main | sed -n 's/^Source-SHA: //p')" = "$DEVBUMP"
t "promote: dev no se toca al promover" test "$(ofile "$DEVPATCH")" = "$DEVFILE_AFTER_DEV"
HP="$(ohead)"
NT="$(tagsn)"
rr "$HP"
prom button "$HP" ""
t "promote: botón vacío con la imagen ya en prod, con dev, no hace nada" test "$RC" -eq 0 -a "$(ov changed)" = false -a "$(tagsn)" = "$NT" -a "$(ohead)" = "$HP"
# un bump de dev posterior no toca prod
code
D2="$SHA"
build_img "$D2" mi-app
rr "$D2"
x bash "$sc/deploy-nonprod.sh" --repo "$S/runner" --source "$D2" --owner "$OWNER" --apps mi-app --envs dev
t "promote: un bump de dev posterior no toca prod" test "$(prod_digest)" = "$(bdig mi-app "$D1")"
# hotfix: una rama fuera de main
DEVBEFORE="$(ofile "$DEVPATCH")"
gw fetch -q origin
gw checkout -q -b hotfix/y v1.0.0
echo hf >>"$S/work/src/app.txt"
gw add -A
gw commit -q -m hotfix
gw push -q origin hotfix/y
HF="$(gw rev-parse HEAD)"
gw tag v1.0.1 "$HF"
gw push -q origin v1.0.1
gw checkout -q main
printf '{"draft":false,"prerelease":false}\n' >"$S/rel/v1.0.1"
build_img "$HF" mi-app
rr "$HF"
: >"$S/gh.log"
prom hotfix "$HF" v1.0.1
t "promote: hotfix escribe prod de main con el commit del hotfix" test "$RC" -eq 0 -a "$(prod_tag)" = 1.0.1 -a "$(prod_digest)" = "$(bdig mi-app "$HF")" -a "$(og log -1 --format=%B main | sed -n 's/^Source-SHA: //p')" = "$HF"
t "promote: hotfix no toca dev" test "$(ofile "$DEVPATCH")" = "$DEVBEFORE"
t "promote: hotfix no crea otro Release" test "$(grep -c 'POST repos/.*/releases' "$S/gh.log")" -eq 0
t "promote: el commit del hotfix no está en main" test "$(og branch --contains "$HF" | grep -c '^ *main$')" -eq 0

# --- check-infra real ----------------------------------------------------------
echo "== check-infra"
if command -v helm >/dev/null && command -v flux >/dev/null && command -v kubeconform >/dev/null && command -v gitleaks >/dev/null; then
  mk ci minimal
  code
  K1="$SHA"
  rr
  bump --source "$K1" --set dev mi-app "sha-${K1:0:12}" "$(bdig mi-app "$K1")" \
    --check-infra "$sc/check-infra.sh" --check-infra-arg --chart-dir --check-infra-arg "$root/charts/app"
  t "check-infra real: el bump sobre el ejemplo pasa y empuja" test "$RC" -eq 0 -a "$(ov changed)" = true
else
  echo "omitido: faltan helm, flux, kubeconform o gitleaks en el PATH (en CI están)"
fi

echo
echo "$PASS ok, $FAILED fallan"
((FAILED == 0))
