{{/* Profile identity and resource bounds. Owned by this chart, not overridable through values. */}}
{{- define "platform.profileName" -}}platform-service{{- end -}}

{{- define "platform.bounds" -}}
{"maxRequestCPUMillis":2000,"maxLimitCPUMillis":4000,"maxRequestMemoryBytes":4294967296,"maxLimitMemoryBytes":8589934592}
{{- end -}}
