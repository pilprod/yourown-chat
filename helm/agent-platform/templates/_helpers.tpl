{{- define "agent-platform.labels" -}}
app.kubernetes.io/part-of: yourown-chat-agent-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Embeddings endpoint: explicit value or the in-cluster server. */}}
{{- define "agent-platform.embeddingsURL" -}}
{{- if .Values.rag.embeddings.url -}}
{{ .Values.rag.embeddings.url }}
{{- else if .Values.rag.embeddingsServer.enabled -}}
http://agent-platform-embeddings.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.rag.embeddingsServer.port }}
{{- else -}}
{{ fail "rag.embeddings.url is required when the in-cluster embeddings server is disabled" }}
{{- end -}}
{{- end }}

{{/* Environment of the activity worker's portable RAG runtime. */}}
{{- define "agent-platform.ragEnv" -}}
- name: RAG_ENABLED
  value: "true"
- name: RAG_DATABASE_URL_FILE
  value: /var/run/secrets/rag/database-url
- name: RAG_MATTERMOST_URL
  value: {{ required "rag.mattermostURL is required" .Values.rag.mattermostURL | quote }}
- name: RAG_MATTERMOST_PUBLIC_URL
  value: {{ .Values.rag.mattermostPublicURL | default .Values.rag.mattermostURL | quote }}
- name: RAG_MATTERMOST_TOKEN_FILE
  value: /var/run/secrets/rag/mattermost-token
- name: RAG_EMBEDDINGS_URL
  value: {{ include "agent-platform.embeddingsURL" . | quote }}
- name: RAG_EMBEDDINGS_MODEL
  value: {{ required "rag.embeddings.model is required" .Values.rag.embeddings.model | quote }}
- name: RAG_EMBEDDINGS_DIMENSIONS
  value: {{ required "rag.embeddings.dimensions is required" .Values.rag.embeddings.dimensions | quote }}
- name: RAG_EMBEDDINGS_BATCH_SIZE
  value: {{ .Values.rag.embeddings.batchSize | quote }}
{{- if .Values.rag.embeddings.tokenSecretId }}
- name: RAG_EMBEDDINGS_TOKEN_FILE
  value: /var/run/secrets/rag/embeddings-token
{{- end }}
- name: RAG_GENERATION_URL
  value: {{ required "rag.generation.url is required when agent_rag_enabled is true" .Values.rag.generation.url | quote }}
- name: RAG_GENERATION_MODEL
  value: {{ required "rag.generation.model is required when agent_rag_enabled is true" .Values.rag.generation.model | quote }}
{{- if .Values.rag.generation.tokenSecretId }}
- name: RAG_GENERATION_TOKEN_FILE
  value: /var/run/secrets/rag/model-api-token
{{- end }}
- name: RAG_GENERATION_MAX_TOKENS
  value: {{ .Values.rag.generation.maxTokens | quote }}
- name: RAG_GENERATION_TEMPERATURE
  value: {{ .Values.rag.generation.temperature | quote }}
- name: RAG_CHUNK_SIZE
  value: {{ .Values.rag.chunkSize | quote }}
- name: RAG_CHUNK_OVERLAP
  value: {{ .Values.rag.chunkOverlap | quote }}
- name: RAG_TOP_K
  value: {{ .Values.rag.topK | quote }}
- name: RAG_MIN_SCORE
  value: {{ .Values.rag.minScore | quote }}
- name: RAG_MAX_CONTEXT_CHARS
  value: {{ .Values.rag.maxContextChars | quote }}
- name: RAG_INDEX_INTERVAL
  value: {{ .Values.rag.indexInterval | quote }}
- name: RAG_HTTP_TIMEOUT
  value: {{ .Values.rag.httpTimeout | quote }}
- name: RAG_PRICE_EMBEDDING_PER_MTOK
  value: {{ .Values.rag.prices.embeddingPerMTok | quote }}
- name: RAG_PRICE_INPUT_PER_MTOK
  value: {{ .Values.rag.prices.inputPerMTok | quote }}
- name: RAG_PRICE_OUTPUT_PER_MTOK
  value: {{ .Values.rag.prices.outputPerMTok | quote }}
{{- end }}
