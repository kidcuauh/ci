#!/usr/bin/env bash
# Decide, sin red, qué versiones de un paquete de contenedores se conservan y cuáles se borran.
# Uso: cleanup-select.sh --versions FILE.json --ids-file FILE [--infra-dir DIR]
#        [--keep-last 20] [--keep-days 14] [--untagged-days 7] [--max-deletions 200] [--now ISO8601]
# Entrada: arreglo JSON de la API de packages (id, name = digest, created_at, metadata.container.tags).
# Salida: tabla en markdown por stdout y los ids a borrar (uno por línea) en --ids-file.
# Sale con error, sin escribir ids, si el JSON no tiene la forma esperada, si no queda nada
# protegido o si los candidatos superan --max-deletions.
#
# Protegidas (conservar): la más reciente del paquete; todo semver; todo lo referenciado
# (digest o tag) bajo --infra-dir; las --keep-last con tag sha- más recientes; las con tag
# más jóvenes que --keep-days. Se borran las demás con tag y las sin tag de
# --untagged-days o más. Las sin tag se rigen solo por --untagged-days: son las que dejó un
# escaneo fallido y no deben esperar --keep-days.
set -euo pipefail

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

versions='' infra='' ids_file='' now=''
keep_last=20 keep_days=14 untagged_days=7 max_del=200
while (($# > 0)); do
  case "$1" in
    --versions) versions="${2-}" ;;
    --infra-dir) infra="${2-}" ;;
    --ids-file) ids_file="${2-}" ;;
    --keep-last) keep_last="${2-}" ;;
    --keep-days) keep_days="${2-}" ;;
    --untagged-days) untagged_days="${2-}" ;;
    --max-deletions) max_del="${2-}" ;;
    --now) now="${2-}" ;;
    *) die "argumento desconocido: $1" ;;
  esac
  shift 2 || die "falta el valor de un argumento"
done

[[ -n "$versions" && -f "$versions" ]] || die "--versions: archivo inexistente"
[[ -n "$ids_file" ]] || die "falta --ids-file"
rm -f "$ids_file"
for n in "$keep_last" "$keep_days" "$untagged_days" "$max_del"; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "los umbrales deben ser enteros no negativos"
done
if [[ -z "$now" ]]; then now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
[[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "--now debe ser AAAA-MM-DDThh:mm:ssZ"
if [[ -n "$infra" && ! -d "$infra" ]]; then die "--infra-dir no existe: $infra"; fi

re_date='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
jq -e --arg re "$re_date" '
  type == "array" and length > 0 and
  all(.[]; type == "object"
    and ((.id | type) == "number" or (.id | type) == "string")
    and ((.name | type) == "string") and (.name | length) > 0
    and ((.created_at | type) == "string") and (.created_at | test($re))
    and ((.metadata.container.tags | type) == "array")
    and all(.metadata.container.tags[]; type == "string"))
' "$versions" >/dev/null 2>&1 || die "el JSON de versiones está vacío o no tiene la forma esperada"

# Ids referenciados bajo infra: el digest como texto, el tag como palabra completa.
refs='[]'
if [[ -n "$infra" ]]; then
  all_infra="$(mktemp)"
  trap 'rm -f "$all_infra"' EXIT
  # -L: sigue enlaces simbólicos (también si $infra lo es); sin él se perdería la protección.
  find -L "$infra/" -type f -not -path '*/.git/*' -exec awk 1 {} + >"$all_infra" 2>/dev/null || true
  if [[ ! -s "$all_infra" ]]; then
    printf 'AVISO --infra-dir %s no aportó ningún texto: no hay protección por referencias\n' "$infra" >&2
  fi
  while IFS=$'\t' read -r id name tags; do
    hit=0
    if grep -aqF -- "$name" "$all_infra" || grep -aqF -- "${name#sha256:}" "$all_infra"; then hit=1; fi
    for t in $tags; do
      if ((hit)); then break; fi
      if [[ ! "$t" =~ ^[A-Za-z0-9._-]+$ ]]; then
        hit=1 # tag raro: se protege por prudencia
        continue
      fi
      esc="${t//./\\.}"
      if grep -aqE -- "(^|[^A-Za-z0-9._-])${esc}($|[^A-Za-z0-9._-])" "$all_infra"; then hit=1; fi
    done
    if ((hit)); then refs="$(jq -c --arg i "$id" '. + [$i]' <<<"$refs")"; fi
  done < <(jq -r '.[] | [(.id | tostring), .name, (.metadata.container.tags | join(" "))] | @tsv' "$versions")
fi

rows="$(jq -c --argjson refs "$refs" --arg now "$now" \
  --argjson keep_last "$keep_last" --argjson keep_days "$keep_days" --argjson untagged_days "$untagged_days" '
  def tg: .metadata.container.tags;
  ($now | fromdateiso8601) as $n
  | (sort_by([.created_at, (.id | tostring)]) | last | (.id | tostring)) as $newest
  | ([.[] | select(tg | any(startswith("sha-")))]
     | sort_by([.created_at, (.id | tostring)]) | reverse | .[0:$keep_last]
     | map(.id | tostring)) as $recent
  | map(
      (.id | tostring) as $id
      | (($n - (.created_at | fromdateiso8601)) / 86400) as $age
      | (tg | length) as $nt
      | (if $id == $newest then "más reciente del paquete"
         elif (tg | any(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]+)?$"))) then "semver"
         elif ($refs | index($id)) != null then "referenciada en infra"
         elif ($recent | index($id)) != null then "entre las sha- más recientes"
         elif $nt > 0 and $age < $keep_days then "tag más joven que keep-days"
         elif $nt == 0 and $age < $untagged_days then "sin tag, joven"
         else null end) as $why
      | {id: $id, name: .name, tags: tg, created_at: .created_at,
         decision: (if $why != null then "conservar" else "borrar" end),
         reason: ($why // (if $nt > 0 then "con tag fuera de la retención" else "sin tag, vieja" end))})
  | .[]' "$versions")"

total="$(jq -s 'length' <<<"$rows")"
keep="$(jq -s '[.[] | select(.decision == "conservar")] | length' <<<"$rows")"
del="$(jq -s '[.[] | select(.decision == "borrar")] | length' <<<"$rows")"
((keep > 0)) || die "el conjunto protegido quedó vacío con $total versiones: parseo roto"

printf 'Versiones: %d. Conservar: %d. Borrar: %d.\n\n' "$total" "$keep" "$del"
printf '| id | digest | tags | creada | decisión | motivo |\n|---|---|---|---|---|---|\n'
jq -rs 'sort_by(.created_at) | reverse | .[]
  | "| \(.id) | `\(.name[0:19])` | \(if (.tags | length) == 0 then "-" else (.tags | join(", ")) end) | \(.created_at) | \(.decision) | \(.reason) |"' <<<"$rows"

if ((del > max_del)); then
  die "$del candidatos superan max-deletions ($max_del): no se borra nada"
fi
jq -rs '.[] | select(.decision == "borrar") | .id' <<<"$rows" >"$ids_file"
