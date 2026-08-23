#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
paused="$(mktemp)"
running="$(mktemp)"
trap 'rm -f "${paused}" "${running}"' EXIT

common=(
  --namespace yourown-agents
  --set yourown_chat_workflow_worker_image=example.invalid/workflow-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  --set yourown_chat_activity_worker_image=example.invalid/activity-worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  --set agent_workflow_worker_gsa=workflow-worker@example.invalid
  --set agent_activity_worker_gsa=activity-worker@example.invalid
  --set cluster_dns_ip=10.30.0.10
)

helm template agent-platform "${repo_root}/helm/agent-platform" \
  "${common[@]}" --set agent_runtime_enabled=false > "${paused}"
helm template agent-platform "${repo_root}/helm/agent-platform" \
  "${common[@]}" \
  --values "${repo_root}/helm/agent-platform/values-running.yaml" > "${running}"

[[ "$(grep -Ec '^  replicas: 0$' "${paused}")" == 2 ]]
[[ "$(grep -Ec '^  replicas: 1$' "${running}")" == 2 ]]
grep -Fq 'image: "example.invalid/workflow-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "${running}"
grep -Fq 'image: "example.invalid/activity-worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' "${running}"
grep -Fq 'value: agent-orchestration-go-v1' "${running}"
grep -Fq 'value: agent-activities-go-v1' "${running}"
grep -Fq 'serviceAccountName: agent-workflow-worker' "${running}"
grep -Fq 'serviceAccountName: agent-activity-worker' "${running}"
grep -Fq 'kubernetes.io/metadata.name: temporal' "${running}"
grep -Fq 'cidr: "10.30.0.10/32"' "${running}"
! grep -Fq 'yourown-chat-control-api' "${running}"
! grep -Eq 'type: (LoadBalancer|NodePort)' "${running}"

grep -Fq -- '- name: agents-paused' "${repo_root}/helm/skaffold-agents.yaml"
grep -Fq -- '- name: agents-running' "${repo_root}/helm/skaffold-agents.yaml"
! grep -Fq 'agent_runtime_enabled' "${repo_root}/helm/skaffold-agents.yaml"
! grep -Fq 'temporal' "${repo_root}/helm/skaffold-agents.yaml"

source_release="${repo_root}/terraform/app-gcp/modules/deploy-release/backend-image.tf"
# Trigger keys are derived from the catalog-supplied repository names.
grep -Fq '"${var.backend_repository_name}-image"' "${source_release}"
grep -Fq '"${var.agents_repository_name}-image"' "${source_release}"
grep -Fq 'services      = "control-api auth-api transport-api identity-api identity-admin identity-migrate"' "${source_release}"
grep -Fq 'services      = "workflow-worker activity-worker rag-migrate"' "${source_release}"
grep -Fq 'for service in control-api workflow-worker activity-worker rag-migrate; do' "${source_release}"
grep -Fq 'repository = google_cloudbuildv2_repository.source[each.value.source].id' "${source_release}"
grep -Fq 'tag           = var.backend_release_tag_regex' "${source_release}"
grep -Fq 'tag           = var.agents_release_tag_regex' "${source_release}"
! grep -Fq 'credential-gcloud.sh' "${source_release}"
grep -Fq 'Release tag $TAG_NAME is not complete yet' "${source_release}"
grep -Fq 'the Terraform Temporal launch gate is closed' "${source_release}"
if grep -Fq 'promote-runtime-tags' "${source_release}"; then
  printf 'Mutable runtime tags must not be promoted\n' >&2
  exit 1
fi
grep -Fq 'yourown_chat_$$(printf' "${source_release}"
! grep -Fq 'yourown_chat_server_image=' "${source_release}"

# --- Portable RAG knowledge base -------------------------------------------
# Disabled by default: no secret mounts, jobs, model servers or RAG env.
! grep -Fq 'RAG_ENABLED' "${running}"
! grep -Fq 'kind: SecretProviderClass' "${running}"
! grep -Fq 'kind: Job' "${running}"
! grep -Fq 'agent-platform-embeddings' "${running}"

rag="$(mktemp)"
trap 'rm -f "${paused}" "${running}" "${rag}"' EXIT
helm template agent-platform "${repo_root}/helm/agent-platform" \
  "${common[@]}" \
  --values "${repo_root}/helm/agent-platform/values-running.yaml" \
  --set agent_rag_enabled=true \
  --set yourown_chat_rag_migrate_image=example.invalid/rag-migrate@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  --set agent_rag_migrate_gsa=rag-migrate@example.invalid \
  --set agent_secret_project=test-project \
  --set agent_cloudsql_ip=10.20.30.40 \
  --set rag.generation.url=http://llm.llm.svc.cluster.local:8000 \
  --set rag.generation.model=qwen2.5-7b-instruct \
  --set rag.embeddingsServer.image=example.invalid/text-embeddings-inference@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  --set 'rag.network.allowNamespaces[0].namespace=llm' \
  --set 'rag.network.allowNamespaces[0].port=8000' > "${rag}"

# Activity worker receives only addresses, model names and secret files.
grep -Fq 'name: RAG_ENABLED' "${rag}"
grep -Fq 'value: /var/run/secrets/rag/database-url' "${rag}"
grep -Fq 'value: /var/run/secrets/rag/mattermost-token' "${rag}"
grep -Fq 'value: "http://agent-platform-embeddings.yourown-agents.svc.cluster.local:8080"' "${rag}"
grep -Fq 'value: "http://llm.llm.svc.cluster.local:8000"' "${rag}"
grep -Fq 'value: "BAAI/bge-m3"' "${rag}"
grep -Fq 'value: "1024"' "${rag}"
! grep -Fq 'RAG_GENERATION_TOKEN_FILE' "${rag}"
! grep -Eq 'postgres://|Bearer|REPLACE_ME' "${rag}"
grep -Fq 'secretProviderClass: agent-rag-activity-gcp' "${rag}"
grep -Fq 'secrets/yourown-chat-agents-runtime-database-url/versions/latest' "${rag}"
grep -Fq 'secrets/yourown-chat-agents-mattermost-token/versions/latest' "${rag}"
! grep -Fq 'yourown-chat-agents-model-api-token' "${rag}"

# Migration job: schema-owning secret, migrate identity, unique name per release.
grep -Eq '^  name: agent-rag-migrate-[0-9a-f]{12}$' "${rag}"
grep -Fq 'serviceAccountName: agent-rag-migrate' "${rag}"
grep -Fq 'secrets/yourown-chat-agents-database-url/versions/latest' "${rag}"
grep -Fq 'name: RAG_RUNTIME_ROLE, value: "yourown_chat_agents_runtime"' "${rag}"
grep -Fq 'iam.gke.io/gcp-service-account: "rag-migrate@example.invalid"' "${rag}"

# Self-hosted embeddings server: ClusterIP only, reachable only from the activity worker.
grep -Fq 'name: agent-platform-embeddings' "${rag}"
grep -Fq 'image: "example.invalid/text-embeddings-inference@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "${rag}"
! grep -Eq 'type: (LoadBalancer|NodePort)' "${rag}"
[[ "$(grep -Fc 'type: ClusterIP' "${rag}")" == 1 ]]
embeddings_policy="$(awk 'BEGIN { RS="---" } /kind: NetworkPolicy/ && /name: agent-platform-embeddings/ { print }' "${rag}")"
grep -Fq 'app: agent-platform-activity-worker' <<<"${embeddings_policy}"

# Network policy: exact Cloud SQL address, model namespace, no public HTTPS unless allowed.
[[ "$(grep -Fc 'cidr: "10.20.30.40/32"' "${rag}")" == 2 ]]
grep -Fq 'kubernetes.io/metadata.name: "llm"' "${rag}"
activity_policy="$(awk 'BEGIN { RS="---" } /kind: NetworkPolicy/ && /name: agent-activity-worker/ { print }' "${rag}")"
! grep -Fq 'cidr: 0.0.0.0/0' <<<"${activity_policy}"

# A RAG release without a generation endpoint must fail the render.
if helm template agent-platform "${repo_root}/helm/agent-platform" "${common[@]}" \
  --set agent_rag_enabled=true \
  --set yourown_chat_rag_migrate_image=example.invalid/rag-migrate@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  --set agent_rag_migrate_gsa=rag-migrate@example.invalid \
  --set agent_secret_project=test-project \
  --set agent_cloudsql_ip=10.20.30.40 \
  --set rag.embeddingsServer.image=example.invalid/tei@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  > /dev/null 2>&1; then
  printf 'RAG render without rag.generation.url must fail\n' >&2
  exit 1
fi

printf 'Agent platform render tests passed\n'
