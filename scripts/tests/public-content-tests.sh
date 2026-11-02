#!/usr/bin/env bash
# Pruebas sin red de scripts/check-public-content.py. Se corre solo:
#   bash scripts/tests/public-content-tests.sh
# Los casos negativos arman sus literales concatenando cadenas, para que este
# archivo pase la misma guardia que prueba.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
chk="$root/scripts/check-public-content.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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

A="empresa-ficticia"
O="org-ajena"

# Lista privada de prueba, con nombres inventados (la real nunca va en el repo).
name="zorb""glub"
printf '# prueba\n%s\n%s\n' "$name" "zorb""28" >"$tmp/names.txt"

# run DIR [opciones...] -> exit de la guardia sobre un árbol; salida en $tmp/out
run() {
  local d="$1"
  shift
  python3 "$chk" --root "$d" --names "$tmp/names.txt" "$@" >"$tmp/out" 2>&1
}

# neg ETIQUETA CONTENIDO [FRAGMENTO-ESPERADO]: el árbol con ese contenido debe fallar
neg() {
  local d="$tmp/neg-$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' "$2" >"$d/a.txt"
  run "$d"
  local rc=$?
  if ((rc == 1)) && grep -q "${3:-a.txt:1}" "$tmp/out"; then result "negativo: $1" 0; else result "negativo: $1" 1 "exit $rc"; fi
}

# pos ETIQUETA CONTENIDO: el árbol con ese contenido debe pasar
pos() {
  local d="$tmp/pos-$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' "$2" >"$d/a.txt"
  run "$d"
  local rc=$?
  if ((rc == 0)); then result "positivo: $1" 0; else result "positivo: $1" 1 "exit $rc: $(head -3 "$tmp/out" | tr '\n' ' ')"; fi
}

# --- positivos ---
pos "texto limpio" "chart oci://ghcr.io/kidcuauh/charts/app y mi-app en example.com"
pos "dominios públicos" "https://fluxcd.io/flux/ https://token.actions.githubusercontent.com https://app.kubernetes.io/name"
pos "owners permitidos" "ghcr.io/mi-org/mi-app github.com/fluxcd/flux2 ghcr.io/\${{ github.repository_owner }}/x"
pos "correos genéricos" "Co-Authored-By: Bot <noreply@""anthropic.com> y 12345+u@users.noreply.github.com y a@example.org"
pos "IP de documentación y loopback" "127.0.0.1 0.0.0.0 192.0.2.10 198.51.100.7 203.0.113.9"
pos "runner de Actions" "ruta /ho""me/runner/work/ci"
pos "extensiones de archivo no son dominios" "values.yaml Chart.yaml install-tools.sh README.md values.schema.json"
pos "dependabot (correo de GitHub, owner y dominio)" "Signed-off-by: dependabot[bot] <support@github.com> github.com/dependabot/x dependabot-badges.githubapp.com"
pos "grupos de API de Kubernetes" "traefik.containo.us monitoring.coreos.com postgresql.cnpg.io"
pos "rutas de contenedor" "/home/app/.cache /home/node/x /root/.npmrc"
pos "userinfo con dominio de ejemplo" "postgres://clave@db.example.com/x y a@sub.example.org"
pos "versión de cuatro partes y máscara de red" "v1.2.3.4 255.255.255.0 api.github.com/repos/\${{ github.repository }}"
# shellcheck disable=SC2016
pos "placeholders de owner" 'ghcr.io/$OWNER/x ghcr.io/${GITHUB_REPOSITORY_OWNER}/x *github.com/*'
pos "IPv6 de documentación y sintaxis de código" "2001:db8::1 ::1 x[0::2] 12:30:45"
pos "digest sha256 de 64 hex" "sha256:0000000000000000000000000000000000000000000000000000000000000000"
mkdir -p "$tmp/pos-sin-lista"
printf 'cliente %s\n' "$name" >"$tmp/pos-sin-lista/a.txt"
python3 "$chk" --root "$tmp/pos-sin-lista" >"$tmp/out" 2>&1
rc=$?
if ((rc == 0)) && grep -q 'solo reglas genéricas' "$tmp/out"; then result "positivo: sin --names solo corren las reglas genéricas" 0; else result "positivo: sin --names solo corren las reglas genéricas" 1 "exit $rc"; fi

# --- negativos ---
neg "dominio ajeno" "visita https://${A}.com/panel"
neg "subdominio de dominio ajeno" "host api.${A}.io"
neg "owner de ghcr ajeno" "ghcr.io/${O}/imagen"
neg "owner de github ajeno" "https://github.com/${O}/repo"
neg "correo" "escribe a persona@${A}.net"
neg "UUID" "id 123e4567-e89b-12d3""-a456-426614174000"
neg "ID hex de 32" "id 0123456789abcdef""0123456789abcdef"
neg "IPv4 privada" "host 10.1.""2.3"
neg "IPv4 pública" "host 8.8.4"".4"
neg "ruta local macOS" "en /Us""ers/alguien/proyecto"
neg "ruta local Linux" "en /ho""me/alguien/proyecto"
neg "ruta de Windows" "en C"":\\Us""ers\\alguien"
neg "referencia de tarea" "ver TA""SK-7"
neg "referencia de ADR" "según AD""R-4"
neg "nombre de la lista" "el cliente $name pidió"
neg "nombre de la lista con mayúsculas" "El Cliente $(printf %s "$name" | tr '[:lower:]' '[:upper:]') pidió"
neg "nombre de la lista dentro de un compuesto" "dominio mi-${name}-prod.test"
neg "nombre de la lista con acento" "${name:0:1}$(printf '\303\263')${name:2}" "a.txt:1"

neg "dominio con comodín" "cert *.${A}.com"
neg "dominio tras arroba" "usuario @${A}.com"
neg "dominio tras guion bajo" "x_${A}.com"
neg "TLD info" "host ${A}.info"
neg "TLD es" "host ${A}.es"
neg "TLD con segundo nivel" "host ${A}.c""om"".br"
neg "TLD de sitio" "ver ${A}.site"
neg "dominio con %2E" "ver ${A}%2Ecom"
neg "dominio con [.]" "ver ${A}[.]com"
neg "dominio en ancho completo" "ver ${A}．com"
neg "noreply de otro dominio" "noreply@${A}.com"
neg "correo con example. falso" "a@example.${A}.com"
neg "owner de docker.io" "docker.io/${O}/app"
neg "owner de quay.io" "quay.io/${O}/app"
neg "owner de gcr.io" "gcr.io/${O}/app"
neg "owner bajo orgs" "github.com/orgs/${O}/projects"
neg "owner tras v2 de ghcr" "ghcr.io/v2/${O}/x"
neg "TASK con guion bajo" "ver TA""SK_7"
neg "TASK con espacio" "ver TA""SK 7"
neg "TASK pegado" "ver TA""SK7"
neg "tarea en español" "ver tar""ea 2.4"
neg "doc numerado" "ver do""c-14"
neg "nombre de la lista pegado en camelCase" "Cliente$(printf %s "${name:0:1}" | tr '[:lower:]' '[:upper:]')${name:1}Infra"
neg "nombre de la lista con dígito" "${name}2"
neg "nombre de la lista con guion bajo" "mi_${name}_x"
neg "nombre de la lista con número separado" "Zorb 28"
neg "nombre de la lista en dos palabras" "${name:0:4} ${name:4}"
neg "nombre de la lista con punto" "${name:0:4}.${name:4}"
neg "dominio ajeno en mayúsculas" "HTTPS://WWW.$(tr '[:lower:]' '[:upper:]' <<<"$A").COM/x"
neg "dominio ajeno con mayúscula inicial" "Empresa-${A#empresa-}.Com"
neg "dominio ajeno con sufijo de certificado" "secreto ${A}.com-tls"
neg "host de red privada" "db.${A}.inter""nal"
neg "TLD excluido en una URL" "https://${A}.p""l/x"
neg "dominio ajeno de segundo nivel con sufijo" "secreto ${A}.com.b""r-tls"
pos "rutas de código y dominios del cluster" "self.app_name settings.org_id {{ .Chart.Home }} {{ .Values.service.internal }} x.svc.cluster.local"
neg "IP con dígitos no ASCII" "host $(printf '\357\274\221\357\274\220').0.0.1"
neg "nombre de la lista con carácter invisible" "${name:0:4}$(printf '\342\200\213')${name:4}"
neg "ID hex de 32 en mayúsculas" "id 0123456789ABCDEF""0123456789ABCDEF"
neg "ID hex de 32 pegado a letras" "tenant0123456789abcdef""0123456789abcdef"
neg "IPv6" "host fd00:"":1"
neg "IPv6 de unicast global" "host 3fff:0:1:"":1"
neg "IPv4 con ceros a la izquierda" "host 010.001.""002.003"
neg "ruta en minúsculas" "en /us""ers/alguien/x"
neg "ruta de /root" "en /ro""ot/proyecto"
neg "ruta de /Volumes" "en /Vol""umes/disco"
neg "ruta de la carpeta de documentos del usuario" "en ~/Doc""uments/x"
neg "ruta con %2F" "en %2FUs""ers%2Falguien"

# El nombre del archivo también cuenta.
d="$tmp/neg-archivo"
mkdir -p "$d"
printf 'limpio\n' >"$d/$name.txt"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'nombre del archivo' "$tmp/out"; then result "negativo: nombre de archivo" 0; else result "negativo: nombre de archivo" 1; fi

# Un hallazgo no imprime el texto sin --show-tokens, y sí con él.
d="$tmp/neg-sin-eco"
if grep -q "$name" "$tmp/neg-nombre de la lista"/a.txt 2>/dev/null; then :; fi
run "$tmp/neg-nombre de la lista"
if ! grep -q "$name" "$tmp/out"; then result "el hallazgo no imprime el nombre" 0; else result "el hallazgo no imprime el nombre" 1; fi
run "$tmp/neg-nombre de la lista" --show-tokens
if grep -q "$name" "$tmp/out"; then result "--show-tokens imprime el nombre" 0; else result "--show-tokens imprime el nombre" 1; fi

# Varios hallazgos se juntan y se numeran por línea.
d="$tmp/neg-varios"
mkdir -p "$d"
printf 'ok\nhost 8.8.4%s\nok\nTA''SK-1\n' ".4" >"$d/a.txt"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'a.txt:2' "$tmp/out" && grep -q 'a.txt:4' "$tmp/out"; then result "junta todos los hallazgos con su línea" 0; else result "junta todos los hallazgos con su línea" 1; fi

# .git y las imágenes binarias se ignoran; otro binario no se puede revisar y falla.
d="$tmp/pos-binario"
mkdir -p "$d/.git"
printf 'ref: %s\n' "/Us""ers/alguien" >"$d/.git/HEAD"
printf '\0\0%s\0' "8.8.4"".4" >"$d/blob.png"
run "$d"
rc=$?
if ((rc == 0)); then result "positivo: ignora .git e imágenes" 0; else result "positivo: ignora .git e imágenes" 1; fi
d="$tmp/neg-binario"
mkdir -p "$d"
printf '\0\0%s\0' "8.8.4"".4" >"$d/blob.tgz"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'binario' "$tmp/out"; then result "negativo: binario no revisable" 0; else result "negativo: binario no revisable" 1 "exit $rc"; fi
d="$tmp/neg-nul"
mkdir -p "$d"
printf '\0host %s%s\n' "$A" ".com" >"$d/a.txt"
run "$d"
rc=$?
if ((rc == 1)); then result "negativo: NUL escondiendo texto" 0; else result "negativo: NUL escondiendo texto" 1 "exit $rc"; fi
d="$tmp/neg-utf16"
mkdir -p "$d"
printf 'host %s%s\n' "$A" ".com" | iconv -f UTF-8 -t UTF-16 >"$d/a.txt"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'a.txt:1' "$tmp/out"; then result "negativo: archivo UTF-16" 0; else result "negativo: archivo UTF-16" 1 "exit $rc"; fi
d="$tmp/neg-enlace"
mkdir -p "$d"
ln -s "/Us""ers/alguien/x" "$d/enlace"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'destino del enlace' "$tmp/out"; then result "negativo: destino de un enlace simbólico" 0; else result "negativo: destino de un enlace simbólico" 1 "exit $rc"; fi

# Texto de PR por variable de entorno.
d="$tmp/pos-pr"
mkdir -p "$d"
printf 'limpio\n' >"$d/a.txt"
PR_TITLE="título limpio" PR_BODY="cuerpo limpio" run "$d" --text-env PR_TITLE --text-env PR_BODY
rc=$?
if ((rc == 0)); then result "positivo: título y cuerpo de PR limpios" 0; else result "positivo: título y cuerpo de PR limpios" 1; fi
PR_TITLE="título limpio" PR_BODY="detalle de $name" run "$d" --text-env PR_TITLE --text-env PR_BODY
rc=$?
if ((rc == 1)) && grep -q 'PR_BODY:1' "$tmp/out"; then result "negativo: cuerpo de PR con nombre de la lista" 0; else result "negativo: cuerpo de PR con nombre de la lista" 1; fi
PR_TITLE="ver AD""R-9" run "$d" --text-env PR_TITLE
rc=$?
if ((rc == 1)) && grep -q 'PR_TITLE:1' "$tmp/out"; then result "negativo: título de PR con referencia interna" 0; else result "negativo: título de PR con referencia interna" 1; fi

# Commits: correos de autor y committer y mensaje.
if command -v git >/dev/null; then
  r="$tmp/repo"
  mkdir -p "$r"
  g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$r" -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
  g init -q
  printf 'limpio\n' >"$r/a.txt"
  g add a.txt
  ok_mail="1+u@users.noreply.github.com"
  GIT_AUTHOR_NAME=u GIT_AUTHOR_EMAIL="$ok_mail" GIT_COMMITTER_NAME=u GIT_COMMITTER_EMAIL="$ok_mail" g commit -q -m "base"
  base="$(g rev-parse HEAD)"
  for caso in limpio correo-autor correo-committer nombre-autor nombre-committer mensaje; do
    a="$ok_mail"
    c="$ok_mail"
    msg="cambio $caso"
    [[ "$caso" != correo-autor ]] || a="persona@${A}.com"
    [[ "$caso" != correo-committer ]] || c="persona@${A}.com"
    [[ "$caso" != mensaje ]] || msg="detalle de $name"
    an=u
    cn=u
    [[ "$caso" != nombre-autor ]] || an="Juan $name"
    [[ "$caso" != nombre-committer ]] || cn="Juan $name"
    GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$a" GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$c" g commit -q --allow-empty -m "$msg"
    run "$r" --commits "$base..HEAD"
    rc=$?
    if [[ "$caso" == limpio ]]; then
      if ((rc == 0)); then result "positivo: commit limpio" 0; else result "positivo: commit limpio" 1 "exit $rc: $(head -3 "$tmp/out" | tr '\n' ' ')"; fi
    else
      if ((rc == 1)) && grep -q 'commit ' "$tmp/out"; then result "negativo: commit con $caso" 0; else result "negativo: commit con $caso" 1 "exit $rc"; fi
    fi
    g reset -q --hard "$base"
  done
  run "$r" --commits "no-existe..HEAD"
  if (($? == 2)); then result "rango de commits inválido sale con 2" 0; else result "rango de commits inválido sale con 2" 1; fi
else
  echo "git no disponible: se omiten las pruebas de commits"
fi

# Uso inválido y lista de nombres.
python3 "$chk" --root "$tmp/pos-pr" --names "$tmp/no-hay-nombres.txt" >/dev/null 2>&1
rc=$?
if ((rc == 2)); then result "lista de nombres ausente sale con 2" 0; else result "lista de nombres ausente sale con 2" 1 "exit $rc"; fi
printf '# solo comentarios\n' >"$tmp/vacio.txt"
python3 "$chk" --root "$tmp/pos-pr" --names "$tmp/vacio.txt" >/dev/null 2>&1
rc=$?
if ((rc == 2)); then result "lista de nombres vacía sale con 2" 0; else result "lista de nombres vacía sale con 2" 1 "exit $rc"; fi
for entrada in "zo" "zorb@glub" "zorb/glub"; do
  printf '%s\n' "$entrada" >"$tmp/invalida.txt"
  python3 "$chk" --root "$tmp/pos-pr" --names "$tmp/invalida.txt" >/dev/null 2>&1
  rc=$?
  if ((rc == 2)); then result "entrada de nombres que nunca coincidiría sale con 2 ($entrada)" 0; else result "entrada de nombres que nunca coincidiría sale con 2 ($entrada)" 1 "exit $rc"; fi
done
# Nombre de la lista partido entre dos líneas y entrada de cinco partes.
d="$tmp/neg-partido"
mkdir -p "$d"
printf 'hola %s\n%s adiós\n' "${name:0:4}" "${name:4}" >"$d/a.txt"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'partido en dos líneas' "$tmp/out"; then result "nombre partido entre dos líneas" 0; else result "nombre partido entre dos líneas" 1 "exit $rc"; fi
printf '%s\n' "${name:0:4}-${name:4}-co-sa-de" >"$tmp/largo.txt"
printf 'owner: %s\n' "${name:0:4}_${name:4}_co_sa_de" >"$d/a.txt"
python3 "$chk" --root "$d" --names "$tmp/largo.txt" >"$tmp/out" 2>&1
rc=$?
if ((rc == 1)); then result "entrada de cinco partes con otro separador" 0; else result "entrada de cinco partes con otro separador" 1 "exit $rc"; fi
# Lista de TLD: una línea que no es un TLD se informa; los comentarios se revisan.
d="$tmp/tld-mala"
mkdir -p "$d/scripts/public-content"
printf '# lista\nCOM\nIO\nno es un tld\n' >"$d/scripts/public-content/tlds.txt"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'tlds.txt:4' "$tmp/out"; then result "línea inválida en la lista de TLD" 0; else result "línea inválida en la lista de TLD" 1 "exit $rc"; fi
printf '# ver %s\nCOM\n' "https://${A}.com" >"$d/scripts/public-content/tlds.txt"
run "$d"
rc=$?
if ((rc == 1)) && grep -q 'tlds.txt:1' "$tmp/out"; then result "comentario de la lista de TLD revisado" 0; else result "comentario de la lista de TLD revisado" 1 "exit $rc"; fi
python3 "$chk" --root "$tmp/no-existe" >/dev/null 2>&1
rc=$?
if ((rc == 2)); then result "raíz inexistente sale con 2" 0; else result "raíz inexistente sale con 2" 1; fi

# Los archivos de datos del repo se leen sin error y la salida dice cuántos nombres cargó.
python3 "$chk" --root "$tmp/pos-pr" >/dev/null 2>&1
rc=$?
if ((rc == 0)); then result "los archivos de datos del repo son válidos" 0; else result "los archivos de datos del repo son válidos" 1; fi
if python3 "$chk" --root "$tmp/pos-pr" --names "$tmp/names.txt" 2>&1 | grep -q '2 nombre(s) de la lista privada'; then result "la salida informa cuántos nombres cargó" 0; else result "la salida informa cuántos nombres cargó" 1; fi

printf '\n%d ok, %d fallo(s)\n' "$PASS" "$FAILED"
((FAILED == 0))
