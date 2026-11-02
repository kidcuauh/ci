{{/*
Selector fijo: nunca cambia entre versiones del chart (cambiarlo obliga a recrear el
Deployment). Recibe un dict con ctx (el contexto raíz) y component.
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Labels del pod: solo name, instance y component. */}}
{{- define "app.podLabels" -}}
app.kubernetes.io/name: app
{{ include "app.selectorLabels" . }}
{{- end -}}

{{/* Labels de metadata. */}}
{{- define "app.labels" -}}
{{ include "app.podLabels" . }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" }}
app.kubernetes.io/version: {{ .ctx.Values.image.tag | quote }}
{{- end -}}

{{/* repo:tag, o repo:tag@digest cuando hay digest. */}}
{{- define "app.image" -}}
{{- $i := .Values.image -}}
{{- if $i.digest -}}
{{- printf "%s:%s@%s" $i.repository $i.tag $i.digest -}}
{{- else -}}
{{- printf "%s:%s" $i.repository $i.tag -}}
{{- end -}}
{{- end -}}

{{/* ServiceAccount efectiva. */}}
{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default .Release.Name .Values.serviceAccount.name -}}
{{- else -}}
{{- .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Secret que crea el controlador de Infisical. */}}
{{- define "app.secretsName" -}}
{{- printf "%s-secrets" .Release.Name -}}
{{- end -}}

{{/*
Probe. Recibe probe (el dict de values) y defaultPort ("http" en el web, vacío en
workers: ahí el puerto es obligatorio).
*/}}
{{- define "app.probe" -}}
{{- $p := deepCopy .probe -}}
{{- if hasKey $p "httpGet" -}}
{{- $port := default .defaultPort $p.httpGet.port -}}
{{- if not $port }}{{ fail "Una probe httpGet de un worker necesita httpGet.port (los workers no tienen puerto http por defecto)." }}{{ end -}}
{{- $_ := set $p "httpGet" (dict "path" $p.httpGet.path "port" $port) -}}
{{- end -}}
{{- if hasKey $p "tcpSocket" -}}
{{- $port := default .defaultPort $p.tcpSocket.port -}}
{{- if not $port }}{{ fail "Una probe tcpSocket de un worker necesita tcpSocket.port (los workers no tienen puerto http por defecto)." }}{{ end -}}
{{- $_ := set $p "tcpSocket" (dict "port" $port) -}}
{{- end -}}
{{- toYaml $p -}}
{{- end -}}

{{/*
Volúmenes comunes: emptyDir de writablePaths, ConfigMaps y llaves de Secret montados
como archivo y, solo en el web, el PVC existente. Recibe ctx y persistence (bool).
*/}}
{{- define "app.volumes" -}}
{{- $v := .ctx.Values -}}
{{- range $i, $path := $v.writablePaths }}
- name: writable-{{ $i }}
  emptyDir:
    sizeLimit: {{ $v.emptyDirSizeLimit | quote }}
{{- end }}
{{- range $i, $f := $v.files.configMaps }}
- name: cm-{{ $i }}
  configMap:
    name: {{ $f.name }}
{{- end }}
{{- range $i, $f := $v.files.secretKeys }}
- name: secret-{{ $i }}
  secret:
    secretName: {{ default (include "app.secretsName" $.ctx) $f.secret }}
    defaultMode: 288
    items:
      - key: {{ $f.key }}
        path: {{ $f.key }}
{{- end }}
{{- if and .persistence $v.persistence.enabled }}
- name: data
  persistentVolumeClaim:
    claimName: {{ $v.persistence.existingClaim }}
{{- end }}
{{- end -}}

{{- define "app.volumeMounts" -}}
{{- $v := .ctx.Values -}}
{{- range $i, $path := $v.writablePaths }}
- name: writable-{{ $i }}
  mountPath: {{ $path }}
{{- end }}
{{- range $i, $f := $v.files.configMaps }}
- name: cm-{{ $i }}
  mountPath: {{ $f.mountPath }}
  readOnly: true
{{- end }}
{{- range $i, $f := $v.files.secretKeys }}
- name: secret-{{ $i }}
  mountPath: {{ $f.mountPath }}
  subPath: {{ $f.key }}
  readOnly: true
{{- end }}
{{- if and .persistence $v.persistence.enabled }}
- name: data
  mountPath: {{ $v.persistence.mountPath }}
  {{- with $v.persistence.subPath }}
  subPath: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Spec de pod común (Pod Security restricted). Recibe un dict con:
ctx, component, command, args, resources, probes, env (lista local), ports (lista
de containerPort), persistence (bool), spread (bool), gracePeriod (bool),
restartPolicy (cadena, opcional).
*/}}
{{- define "app.podSpec" -}}
{{- $ctx := .ctx -}}
{{- $v := $ctx.Values -}}
serviceAccountName: {{ include "app.serviceAccountName" $ctx }}
automountServiceAccountToken: false
enableServiceLinks: false
priorityClassName: {{ $v.priorityClassName }}
{{- with $v.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- with .restartPolicy }}
restartPolicy: {{ . }}
{{- end }}
{{- if .gracePeriod }}
terminationGracePeriodSeconds: {{ $v.terminationGracePeriodSeconds }}
{{- end }}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ int64 $v.securityContext.runAsUser }}
  runAsGroup: {{ int64 $v.securityContext.runAsGroup }}
  fsGroup: {{ int64 $v.securityContext.fsGroup }}
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
{{- if ne $v.placement.zone "any" }}
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values:
                - {{ $v.placement.zone }}
{{- end }}
{{- if .spread }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: {{ $v.placement.whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        {{- include "app.selectorLabels" . | nindent 8 }}
    matchLabelKeys:
      - pod-template-hash
{{- end }}
containers:
  - name: app
    image: {{ include "app.image" $ctx | quote }}
    imagePullPolicy: {{ $v.image.pullPolicy }}
    {{- with .command }}
    command:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .args }}
    args:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .ports }}
    ports:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- $env := concat $v.env (default (list) .env) }}
    {{- with $env }}
    env:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if $v.secrets.infisical.enabled }}
    envFrom:
      - secretRef:
          name: {{ include "app.secretsName" $ctx }}
    {{- end }}
    resources:
      {{- toYaml .resources | nindent 6 }}
    {{- with .probes }}
    {{- with .startup }}
    startupProbe:
      {{- include "app.probe" (dict "probe" . "defaultPort" $.defaultPort) | nindent 6 }}
    {{- end }}
    {{- with .readiness }}
    readinessProbe:
      {{- include "app.probe" (dict "probe" . "defaultPort" $.defaultPort) | nindent 6 }}
    {{- end }}
    {{- with .liveness }}
    livenessProbe:
      {{- include "app.probe" (dict "probe" . "defaultPort" $.defaultPort) | nindent 6 }}
    {{- end }}
    {{- end }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      capabilities:
        drop:
          - ALL
    {{- $mounts := include "app.volumeMounts" . }}
    {{- if $mounts }}
    volumeMounts:
      {{- $mounts | trim | nindent 6 }}
    {{- end }}
{{- $vols := include "app.volumes" . }}
{{- if $vols }}
volumes:
  {{- $vols | trim | nindent 2 }}
{{- end }}
{{- end -}}
