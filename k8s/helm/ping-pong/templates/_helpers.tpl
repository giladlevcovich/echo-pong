{{- define "ping-pong.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ping-pong.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "ping-pong.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "ping-pong.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ping-pong.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "ping-pong.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "ping-pong.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "ping-pong.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ping-pong.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "ping-pong.secretName" -}}
{{- if .Values.secret.create }}
{{- include "ping-pong.fullname" . }}
{{- else }}
{{- required "secret.existingSecret must be configured when secret.create=false" .Values.secret.existingSecret }}
{{- end }}
{{- end }}