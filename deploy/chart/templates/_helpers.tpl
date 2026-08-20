{{/*
Chart name (overridable by the release-name-aware fullname elsewhere if needed).
*/}}
{{- define "realm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every object.
*/}}
{{- define "realm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "realm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Where everything dials redis. The chart's own redis, or an external one when that is disabled —
realmd, d2ingress and both kinds of game server all resolve it through here so they cannot end up
pointed at different stores.
*/}}
{{- define "realm.redisAddr" -}}
{{- if .Values.redis.enabled -}}
realmd-redis:6379
{{- else -}}
{{ required "redis.external.addr is required when redis.enabled is false: every component dials redis and none of them has a default" .Values.redis.external.addr }}
{{- end -}}
{{- end -}}

{{/*
Per-component selector labels. Call with a dict {root, component}.
*/}}
{{- define "realm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "realm.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
