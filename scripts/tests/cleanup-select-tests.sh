#!/usr/bin/env bash
# Pruebas sin red de scripts/cleanup-select.sh. Las carga run.sh (usa result, $tmp, $here, $root).
# shellcheck shell=bash disable=SC2154

cs_now="2026-06-30T00:00:00Z"
cs_infra="$here/fixtures/cleanup/infra"
cs_sel="$root/scripts/cleanup-select.sh"
cs_dig() { printf 'sha256:%064d' "$1"; }

# cs_ver ID DIAS TAG... -> una versión creada hace DIAS días (sin TAG = sin tag)
cs_ver() {
  local id="$1" days="$2"
  shift 2
  jq -nc --argjson id "$id" --arg name "$(cs_dig "$id")" --arg now "$cs_now" --argjson d "$days" '
    $ARGS.positional as $t
    | {id: $id, name: $name, created_at: (($now | fromdateiso8601) - $d * 86400 | todate),
       metadata: {container: {tags: $t}}}' --args "$@"
}

# cs_run ARCHIVO [opciones...] -> exit de cleanup-select con --now fijo; ids en $tmp/cs.ids
cs_run() {
  local f="$1"
  shift
  bash "$cs_sel" --versions "$f" --ids-file "$tmp/cs.ids" --now "$cs_now" "$@" >"$tmp/cs.out" 2>"$tmp/cs.err"
}
cs_deleted() { grep -qx "$1" "$tmp/cs.ids"; }

# Caso general: ids 1.. por antigüedad creciente
{
  cs_ver 1 1 sha-nuevo0000001
  cs_ver 3 90 v1.2.3           # semver
  cs_ver 4 100 rama-vieja # tag que no es sha- ni semver
  cs_ver 5 20 # sin tag, vieja
  cs_ver 6 3  # sin tag, joven
  cs_ver 7 10 # sin tag de 10 días: se borra (untagged-days = 7)
  cs_ver 8 5 sha-medio0000008
  cs_ver 9 80 # sin tag, digest referenciado en infra
} | jq -s . >"$tmp/cs-general.json"
sed -i.bak "s/$(cs_dig 9)/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" "$tmp/cs-general.json"
rm -f "$tmp/cs-general.json.bak"

cs_run "$tmp/cs-general.json" --infra-dir "$cs_infra"
expect_exit "cleanup: caso general sale 0" 0 $?
! cs_deleted 3
result "cleanup: semver viejo no se borra" $?
cs_deleted 4
result "cleanup: tag viejo que no es sha- ni semver se borra" $?
cs_deleted 5
result "cleanup: sin tag de más de 7 días se borra" $?
! cs_deleted 6
result "cleanup: sin tag de menos de 7 días se conserva" $?
cs_deleted 7
result "cleanup: sin tag de 10 días se borra aunque keep-days sea 14" $?
! cs_deleted 8
result "cleanup: con tag de menos de 14 días se conserva" $?
! cs_deleted 9
result "cleanup: digest referenciado en infra se conserva sin tag" $?
! cs_deleted 1
result "cleanup: la versión más reciente nunca se borra" $?
grep -q '^| id |' "$tmp/cs.out"
result "cleanup: imprime la tabla" $?

# Las 20 sha- más recientes se conservan (25 versiones, de 20 a 44 días)
{ for i in $(seq 1 25); do cs_ver "$i" "$((19 + i))" "sha-$(printf '%012d' "$i")"; done; } | jq -s . >"$tmp/cs-25.json"
cs_run "$tmp/cs-25.json"
n_del="$(wc -l <"$tmp/cs.ids" | tr -d ' ')"
[[ "$n_del" == 5 ]] && cs_deleted 25 && cs_deleted 21 && ! cs_deleted 20
result "cleanup: conserva las 20 sha- más recientes y borra las 5 más viejas" $? "borra $n_del"

# La más vieja de las 25 lleva un tag referenciado en infra: se conserva solo con infra-dir
jq -c '(.[] | select(.id == 25) | .metadata.container.tags) = ["sha-0ld000000001"]' "$tmp/cs-25.json" >"$tmp/cs-25r.json"
cs_run "$tmp/cs-25r.json" --infra-dir "$cs_infra"
n_del="$(wc -l <"$tmp/cs.ids" | tr -d ' ')"
[[ "$n_del" == 4 ]] && ! cs_deleted 25
result "cleanup: sha- viejo referenciado en infra nunca se borra" $? "borra $n_del"
cs_run "$tmp/cs-25r.json"
cs_deleted 25
result "cleanup: sin infra-dir ese mismo sha- viejo sí se borra" $?
# Un tag que solo es prefijo del referenciado no cuenta
jq -c '(.[] | select(.id == 25) | .metadata.container.tags) = ["sha-0ld0000000"]' "$tmp/cs-25.json" >"$tmp/cs-25p.json"
cs_run "$tmp/cs-25p.json" --infra-dir "$cs_infra"
cs_deleted 25
result "cleanup: el tag se compara como palabra completa" $?

# 22 versiones sha- jóvenes: todas se conservan (keep-days)
{ for i in $(seq 1 22); do cs_ver "$i" "$((i % 10 + 1))" "sha-$(printf '%012d' "$i")"; done; } | jq -s . >"$tmp/cs-young.json"
cs_run "$tmp/cs-young.json"
[[ ! -s "$tmp/cs.ids" ]]
result "cleanup: lo menor a keep-days se conserva aunque pase de keep-last" $?

# Paquete de una sola versión vieja: nunca queda vacío
{ cs_ver 1 400; } | jq -s . >"$tmp/cs-one.json"
cs_run "$tmp/cs-one.json"
code=$?
expect_exit "cleanup: una sola versión vieja sale 0" 0 $code
[[ ! -s "$tmp/cs.ids" ]]
result "cleanup: una sola versión vieja no se borra" $?

# Formas inválidas
: >"$tmp/cs-vacio.json"
cs_run "$tmp/cs-vacio.json"
expect_exit "cleanup: archivo vacío falla" 1 $?
echo '[]' >"$tmp/cs-arr.json"
cs_run "$tmp/cs-arr.json"
expect_exit "cleanup: arreglo vacío falla" 1 $?
echo '{"no": ' >"$tmp/cs-mal.json"
cs_run "$tmp/cs-mal.json"
expect_exit "cleanup: JSON mal formado falla" 1 $?
echo '[{"id": 1, "name": "x"}]' >"$tmp/cs-forma.json"
cs_run "$tmp/cs-forma.json"
expect_exit "cleanup: faltan campos de la API y falla" 1 $?
echo '{"message":"Not Found"}' >"$tmp/cs-404.json"
cs_run "$tmp/cs-404.json"
expect_exit "cleanup: respuesta de error de la API falla" 1 $?

# max-deletions
cs_run "$tmp/cs-general.json" --infra-dir "$cs_infra" --max-deletions 2
expect_exit "cleanup: más candidatos que max-deletions falla" 1 $?
[[ ! -s "$tmp/cs.ids" ]]
result "cleanup: con max-deletions excedido no escribe ids" $?
cs_run "$tmp/cs-general.json" --infra-dir "$cs_infra" --max-deletions 3
expect_exit "cleanup: justo en max-deletions pasa" 0 $?

cs_run "$tmp/cs-general.json" --keep-last abc
expect_exit "cleanup: umbral no numérico falla" 1 $?

# Semver con sufijo (pre-release/build) también se protege
{
  cs_ver 1 1 sha-nuevo0000001
  cs_ver 2 100 v1.2.3-rc.1
  cs_ver 3 100 1.2.3-beta
  cs_ver 4 100 v1.2.3+build.5
} | jq -s . >"$tmp/cs-pre.json"
cs_run "$tmp/cs-pre.json" --keep-last 0
[[ ! -s "$tmp/cs.ids" ]]
result "cleanup: semver con sufijo pre-release o build se conserva" $?

# infra con enlaces simbólicos (archivo, directorio y raíz) sigue protegiendo
mkdir -p "$tmp/cs-real" "$tmp/cs-i1" "$tmp/cs-i2"
printf 'image:\n  tag: sha-linked000001\n' >"$tmp/cs-real/f.yaml"
ln -s "$tmp/cs-real/f.yaml" "$tmp/cs-i1/f.yaml"
ln -s "$tmp/cs-real" "$tmp/cs-i2/dir"
ln -s "$tmp/cs-real" "$tmp/cs-i3"
{ cs_ver 1 1 sha-nuevo0000001; cs_ver 5 100 sha-linked000001; } | jq -s . >"$tmp/cs-link.json"
for d in cs-i1 cs-i2 cs-i3; do
  cs_run "$tmp/cs-link.json" --infra-dir "$tmp/$d" --keep-last 0
  ! cs_deleted 5
  result "cleanup: enlace simbólico en infra ($d) protege el tag" $?
done

# digest sin prefijo sha256: también protege
mkdir -p "$tmp/cs-i4"
printf 'digest: %064d\n' 6 >"$tmp/cs-i4/v.yaml"
{ cs_ver 1 1 sha-nuevo0000001; cs_ver 6 100; } | jq -s . >"$tmp/cs-bare.json"
cs_run "$tmp/cs-bare.json" --infra-dir "$tmp/cs-i4" --keep-last 0
! cs_deleted 6
result "cleanup: digest referenciado sin prefijo sha256: se conserva" $?

# infra sin texto: avisa
mkdir -p "$tmp/cs-i5"
: >"$tmp/cs-i5/.gitkeep"
cs_run "$tmp/cs-bare.json" --infra-dir "$tmp/cs-i5" --keep-last 0
grep -q AVISO "$tmp/cs.err"
result "cleanup: infra sin texto avisa" $?
