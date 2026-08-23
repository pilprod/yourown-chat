{{/* Profile-owned resource bounds. Not overridable through values. */}}
{{- define "platform.bounds" -}}
{"maxRequestCPUMillis":2000,"maxLimitCPUMillis":4000,"maxRequestMemoryBytes":4294967296,"maxLimitMemoryBytes":8589934592}
{{- end -}}
