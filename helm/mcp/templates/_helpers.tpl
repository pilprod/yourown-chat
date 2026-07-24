{{/*
Merge a per-server override with the chart-wide default: the server entry wins
when it sets the field, otherwise the value from .Values.defaults applies.
Usage: include "mcp-servers.valueOrDefault" (dict "server" $server "defaults" $.Values.defaults "key" "resources")
*/}}
{{- define "mcp-servers.valueOrDefault" -}}
{{- $server := .server -}}
{{- $defaults := .defaults -}}
{{- $key := .key -}}
{{- if hasKey $server $key -}}
{{- get $server $key | toYaml -}}
{{- else -}}
{{- get $defaults $key | toYaml -}}
{{- end -}}
{{- end }}

{{/* Stable resource name with an optional dev-release prefix. */}}
{{- define "mcp-servers.serverName" -}}
{{- printf "%smcp-%s" (.root.Values.namePrefix | default "") .name | trunc 63 | trimSuffix "-" -}}
{{- end }}
