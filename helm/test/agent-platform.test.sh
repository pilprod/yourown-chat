#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
paused="$(mktemp)"
running="$(mktemp)"
trap 'rm -f "${paused}" "${running}"' EXIT

common=(
  --namespace yourown-agents
  --set yourown_chat_control_api_image=example.invalid/control-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --set yourown_chat_workflow_worker_image=example.invalid/workflow-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  --set yourown_chat_activity_worker_image=example.invalid/activity-worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  --set backend_control_api_gsa=control-api@example.invalid
  --set agent_workflow_worker_gsa=workflow-worker@example.invalid
  --set agent_activity_worker_gsa=activity-worker@example.invalid
  --set agent_secret_project=test-project
)

helm template agent-platform "${repo_root}/helm/agent-platform" \
  "${common[@]}" --set agent_runtime_enabled=false > "${paused}"
helm template agent-platform "${repo_root}/helm/agent-platform" \
  "${common[@]}" \
  --values "${repo_root}/helm/agent-platform/values-running.yaml" > "${running}"

[[ "$(grep -Ec '^  replicas: 0$' "${paused}")" == 3 ]]
[[ "$(grep -Ec '^  replicas: 1$' "${running}")" == 3 ]]
grep -Fq 'secretProviderClass: backend-control-api-gcp' "${running}"
grep -Fq 'image: "example.invalid/control-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "${running}"
grep -Fq 'image: "example.invalid/workflow-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "${running}"
grep -Fq 'image: "example.invalid/activity-worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' "${running}"
grep -Fq 'value: agent-orchestration-go-v1' "${running}"
grep -Fq 'value: agent-activities-go-v1' "${running}"
grep -Fq 'serviceAccountName: backend-control-api' "${running}"
grep -Fq 'serviceAccountName: agent-workflow-worker' "${running}"
grep -Fq 'serviceAccountName: agent-activity-worker' "${running}"
grep -Fq 'kubernetes.io/metadata.name: "mattermost"' "${running}"
grep -Fq 'kubernetes.io/metadata.name: temporal' "${running}"
! grep -Eq 'type: (LoadBalancer|NodePort)' "${running}"

grep -Fq -- '- name: agents-paused' "${repo_root}/helm/skaffold-agents.yaml"
grep -Fq -- '- name: agents-running' "${repo_root}/helm/skaffold-agents.yaml"
! grep -Fq 'agent_runtime_enabled' "${repo_root}/helm/skaffold-agents.yaml"
! grep -Fq 'temporal' "${repo_root}/helm/skaffold-agents.yaml"

source_release="${repo_root}/terraform/app-gcp/modules/deploy-release/backend-image.tf"
grep -Fq '"yourown-chat-server-image"' "${source_release}"
grep -Fq '"yourown-chat-agents-image"' "${source_release}"
grep -Fq 'services      = "control-api"' "${source_release}"
grep -Fq 'services      = "workflow-worker activity-worker"' "${source_release}"
grep -Fq 'repository = google_cloudbuildv2_repository.source[each.value.source].id' "${source_release}"
grep -Fq 'Release tag $TAG_NAME is not complete yet' "${source_release}"
grep -Fq 'the Terraform Temporal launch gate is closed' "${source_release}"
if grep -Fq 'promote-runtime-tags' "${source_release}"; then
  printf 'Mutable runtime tags must not be promoted\n' >&2
  exit 1
fi
grep -Fq 'yourown_chat_$$(printf' "${source_release}"
! grep -Fq 'yourown_chat_server_image=' "${source_release}"

printf 'Agent platform render tests passed\n'
