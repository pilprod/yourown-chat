{{- define "agent-platform.labels" -}}
app.kubernetes.io/part-of: yourown-chat-agent-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
