#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
command="${1:-help}"

project="${GCP_PROJECT:-yourown-chat}"
region="${GCP_REGION:-europe-west3}"
repository="${ARTIFACT_REPOSITORY:-docker}"

local_compose() {
  local agents_repo="${YOUROWN_CHAT_AGENTS_DIR:-${repo_root}/../yourown-chat-agents}"
  [[ -f "${agents_repo}/compose.yaml" ]] || {
    printf 'Agent workload repository is missing: %s\n' "${agents_repo}" >&2
    exit 1
  }
  docker compose --project-directory "${agents_repo}" \
    -f "${agents_repo}/compose.yaml" "$@"
}

cloud_release() {
  local pipeline="$1"
  local label="$2"
  local image_prefix="${region}-docker.pkg.dev/${project}/${repository}/yourown-chat"
  local image_tag
  local control_api_digest
  local workflow_worker_digest
  local activity_worker_digest
  local release_id

  image_tag="$(gcloud artifacts docker tags list "${image_prefix}-control-api" \
    --project "${project}" \
    --filter="tag~'/tags/[0-9]+\\.[0-9]+\\.[0-9]+$'" \
    --format='value(tag)' | sort -V | tail -n1)"
  image_tag="${image_tag##*/}"
  [[ -n "${image_tag}" ]] || {
    printf 'No immutable YourOwn.Chat backend release tag was found\n' >&2
    exit 1
  }
  control_api_digest="$(gcloud artifacts docker images describe "${image_prefix}-control-api:${image_tag}" \
    --project "${project}" --format='value(image_summary.digest)')"
  workflow_worker_digest="$(gcloud artifacts docker images describe "${image_prefix}-workflow-worker:${image_tag}" \
    --project "${project}" --format='value(image_summary.digest)')"
  activity_worker_digest="$(gcloud artifacts docker images describe "${image_prefix}-activity-worker:${image_tag}" \
    --project "${project}" --format='value(image_summary.digest)')"
  [[ -n "${control_api_digest}" && -n "${workflow_worker_digest}" && -n "${activity_worker_digest}" ]] || {
    printf 'One or more agent microservice digests were not found\n' >&2
    exit 1
  }
  release_id="agents-${label}-$(date -u +%Y%m%d-%H%M%S)"
  (
    cd "${script_dir}"
    gcloud deploy releases create "${release_id}" \
      --project "${project}" \
      --region "${region}" \
      --delivery-pipeline "${pipeline}" \
      --source . \
      --skaffold-file skaffold-agents.yaml \
      --deploy-parameters "yourown_chat_control_api_image=${image_prefix}-control-api@${control_api_digest},yourown_chat_workflow_worker_image=${image_prefix}-workflow-worker@${workflow_worker_digest},yourown_chat_activity_worker_image=${image_prefix}-activity-worker@${activity_worker_digest}"
  )
  printf 'Release %s created. Approve target %s-pilot in Cloud Deploy.\n' "${release_id}" "${pipeline}"
}

case "${command}" in
  local-start)
    local_compose up -d --build
    ;;
  local-pause)
    local_compose stop control-api workflow-worker activity-worker temporal
    ;;
  local-status)
    local_compose ps
    ;;
  local-stop)
    # Deliberately no --volumes: local Temporal state remains recoverable.
    local_compose down
    ;;
  cloud-start)
    cloud_release agents-start start
    ;;
  cloud-pause)
    cloud_release agents-pause pause
    ;;
  cloud-pause-now)
    # Emergency, reversible stop. Follow with cloud-pause to record the state
    # in an approved Cloud Deploy release.
    kubectl scale deployment --all --replicas=0 --namespace yourown-agents
    ;;
  cloud-status)
    kubectl get deployment,pod --namespace yourown-agents
    kubectl get deployment,pod --namespace temporal
    ;;
  help|*)
    printf '%s\n' \
      'Usage: helm/agent-pilot.sh COMMAND' \
      '' \
      'Local:  local-start | local-pause | local-status | local-stop' \
      'Cloud:  cloud-start | cloud-pause | cloud-pause-now | cloud-status'
    ;;
esac
