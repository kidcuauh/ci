{{/*
Reglas que el schema no puede ver. Cada fail dice qué cambiar.
*/}}
{{- define "app.validate" -}}
{{- $v := .Values -}}
{{- $rel := .Release.Name -}}
{{- $reserved := list "tenant-reconciler" "infisical-sync" "alloy" "kustomize-controller" "helm-controller" "default" -}}

{{- if not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $rel) -}}
{{- fail (printf "El nombre del release %q no es válido: usa minúsculas, dígitos y guiones, empezando por una letra." $rel) -}}
{{- end -}}
{{- if gt (len $rel) 40 -}}
{{- fail (printf "El nombre del release %q tiene %d caracteres: el máximo es 40." $rel (len $rel)) -}}
{{- end -}}
{{- if or (has $rel $reserved) (hasSuffix "-ops" $rel) -}}
{{- fail (printf "El nombre del release %q está reservado (tenant-reconciler, infisical-sync, alloy, kustomize-controller, helm-controller, default o terminado en -ops): cambia metadata.name del HelmRelease." $rel) -}}
{{- end -}}

{{- $sa := $v.serviceAccount -}}
{{- if $sa.create -}}
{{- $n := default $rel $sa.name -}}
{{- if or (has $n $reserved) (hasSuffix "-ops" $n) -}}
{{- fail (printf "serviceAccount.name %q está reservado: elige otro nombre o deja el valor vacío para usar el nombre del release." $n) -}}
{{- end -}}
{{- else -}}
{{- if not $sa.name -}}
{{- fail "serviceAccount.create es false: serviceAccount.name es obligatorio y debe ser el de una ServiceAccount que ya existe." -}}
{{- end -}}
{{- if or (and (has $sa.name $reserved) (ne $sa.name "alloy")) (hasSuffix "-ops" $sa.name) -}}
{{- fail (printf "serviceAccount.name %q está reservado: usa otra ServiceAccount." $sa.name) -}}
{{- end -}}
{{- end -}}

{{- if and (not $v.web.enabled) $v.web.ingress.enabled -}}
{{- fail "web.ingress.enabled necesita web.enabled: true." -}}
{{- end -}}
{{- if and (not $v.web.enabled) $v.persistence.enabled -}}
{{- fail "persistence.enabled necesita web.enabled: true: el PVC solo se monta en el web." -}}
{{- end -}}
{{- if and (not $v.web.enabled) (not $v.workers) (not $v.cronJobs) (not $v.migrations.enabled) -}}
{{- fail "El release no renderiza nada: activa web.enabled, agrega workers o cronJobs, o activa migrations.enabled." -}}
{{- end -}}

{{- $names := dict -}}
{{- range $w := $v.workers -}}
{{- if hasKey $names $w.name -}}
{{- fail (printf "Hay dos workers con el nombre %q: los nombres deben ser únicos." $w.name) -}}
{{- end -}}
{{- $_ := set $names $w.name true -}}
{{- if gt (len (printf "%s-%s" $rel $w.name)) 63 -}}
{{- fail (printf "El worker %q da el nombre %q, de más de 63 caracteres: acorta el nombre del worker." $w.name (printf "%s-%s" $rel $w.name)) -}}
{{- end -}}
{{- end -}}
{{- $cnames := dict -}}
{{- range $c := $v.cronJobs -}}
{{- if hasKey $cnames $c.name -}}
{{- fail (printf "Hay dos cronJobs con el nombre %q: los nombres deben ser únicos." $c.name) -}}
{{- end -}}
{{- $_ := set $cnames $c.name true -}}
{{- if gt (len (printf "%s-%s" $rel $c.name)) 52 -}}
{{- fail (printf "El cronJob %q da el nombre %q, de más de 52 caracteres (los Jobs agregan un sufijo): acorta el nombre." $c.name (printf "%s-%s" $rel $c.name)) -}}
{{- end -}}
{{- end -}}

{{- $ports := dict "http" true -}}
{{- $nums := dict (toString $v.web.port) true -}}
{{- range $p := $v.web.extraPorts -}}
{{- if hasKey $ports $p.name -}}
{{- fail (printf "web.extraPorts repite el nombre de puerto %q." $p.name) -}}
{{- end -}}
{{- $key := printf "%v/%s" $p.port (default "TCP" $p.protocol) -}}
{{- if or (hasKey $nums $key) (and (eq (default "TCP" $p.protocol) "TCP") (hasKey $nums (toString $p.port))) -}}
{{- fail (printf "web.extraPorts: el puerto %v ya está en uso por web.port u otro puerto extra." $p.port) -}}
{{- end -}}
{{- $_ := set $ports $p.name true -}}
{{- $_ := set $nums $key true -}}
{{- if eq (default "TCP" $p.protocol) "TCP" -}}
{{- $_ := set $nums (toString $p.port) true -}}
{{- end -}}
{{- end -}}

{{- $probeKinds := list "startup" "readiness" "liveness" -}}
{{- $probePorts := list -}}
{{- if $v.web.enabled -}}
{{- range $k := $probeKinds -}}
{{- $pr := get (default (dict) $v.web.probes) $k -}}
{{- if $pr -}}
{{- $pp := "" -}}
{{- if and (kindIs "map" $pr.httpGet) $pr.httpGet.port -}}{{- $pp = $pr.httpGet.port -}}{{- end -}}
{{- if and (kindIs "map" $pr.tcpSocket) $pr.tcpSocket.port -}}{{- $pp = $pr.tcpSocket.port -}}{{- end -}}
{{- if and (kindIs "string" $pp) $pp (not (hasKey $ports $pp)) -}}
{{- fail (printf "web.probes.%s: el puerto %q no está declarado: usa http, el nombre de un web.extraPorts o un número." $k $pp) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $w := $v.workers -}}
{{- range $k := $probeKinds -}}
{{- $pr := get (default (dict) $w.probes) $k -}}
{{- if $pr -}}
{{- $pp := "" -}}
{{- if and (kindIs "map" $pr.httpGet) $pr.httpGet.port -}}{{- $pp = $pr.httpGet.port -}}{{- end -}}
{{- if and (kindIs "map" $pr.tcpSocket) $pr.tcpSocket.port -}}{{- $pp = $pr.tcpSocket.port -}}{{- end -}}
{{- if kindIs "string" $pp -}}
{{- if $pp -}}
{{- fail (printf "workers[%s].probes.%s: el puerto %q es un nombre, pero los workers no declaran puertos: usa un número." $w.name $k $pp) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- if not $v.secrets.infisical.enabled -}}
{{- range $f := $v.files.secretKeys -}}
{{- if not $f.secret -}}
{{- fail (printf "files.secretKeys con secret vacío (la llave de %s-secrets) exige secrets.infisical.enabled: true; o indica el nombre de un Secret de la lista permitida." $rel) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- $mounts := dict -}}
{{- range $p := $v.writablePaths -}}
{{- if hasKey $mounts $p -}}
{{- fail (printf "mountPath %q repetido: writablePaths, files y persistence deben usar rutas distintas." $p) -}}
{{- end -}}
{{- $_ := set $mounts $p true -}}
{{- end -}}
{{- range $f := $v.files.configMaps -}}
{{- if hasKey $mounts $f.mountPath -}}
{{- fail (printf "mountPath %q repetido: writablePaths, files y persistence deben usar rutas distintas." $f.mountPath) -}}
{{- end -}}
{{- $_ := set $mounts $f.mountPath true -}}
{{- end -}}
{{- range $f := $v.files.secretKeys -}}
{{- if hasKey $mounts $f.mountPath -}}
{{- fail (printf "mountPath %q repetido: writablePaths, files y persistence deben usar rutas distintas." $f.mountPath) -}}
{{- end -}}
{{- $_ := set $mounts $f.mountPath true -}}
{{- end -}}
{{- if and $v.persistence.enabled (hasKey $mounts $v.persistence.mountPath) -}}
{{- fail (printf "mountPath %q repetido: persistence.mountPath choca con otro montaje." $v.persistence.mountPath) -}}
{{- end -}}
{{- end -}}
