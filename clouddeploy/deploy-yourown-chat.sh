#!/usr/bin/env bash
set -euo pipefail

source clouddeploy-release.env

apk add --no-cache bash ca-certificates curl helm kubectl make python3

deploy_started_at="$(date -u +%s)"
deploy_name="yourown-chat deploy"
deploy_release="${CLOUD_DEPLOY_RELEASE:-manual-release}"
deploy_rollout="${CLOUD_DEPLOY_ROLLOUT:-manual-rollout}"
deploy_target="${CLOUD_DEPLOY_TARGET:-yourown-chat-rke2}"
deploy_region="${CLOUD_DEPLOY_LOCATION:-southamerica-east1}"
deploy_pipeline="${CLOUD_DEPLOY_DELIVERY_PIPELINE:-yourown-chat}"
deploy_log="/tmp/mattermost-deploy-${deploy_rollout}.log"
workflow_root_post_id="${MATTERMOST_WORKFLOW_ROOT_POST_ID:-}"

access_secret_version() {
  local version_name="$1"
  if [[ "${version_name}" =~ ^projects/([^/]+)/secrets/([^/]+)/versions/([^/]+)$ ]]; then
    local secret_project="${BASH_REMATCH[1]}"
    local secret_id="${BASH_REMATCH[2]}"
    local secret_version="${BASH_REMATCH[3]}"
    gcloud secrets versions access "${secret_version}" --project="${secret_project}" --secret="${secret_id}"
  else
    gcloud secrets versions access "${version_name}" --project="${TARGET_PROJECT_ID}"
  fi
}

if [[ -n "${MATTERMOST_CICD_TOKEN_ID_SECRET_VERSION:-}" ]]; then
  MATTERMOST_CICD_TOKEN_ID="$(access_secret_version "${MATTERMOST_CICD_TOKEN_ID_SECRET_VERSION}" 2>/dev/null || true)"
fi
if [[ -n "${MATTERMOST_CICD_TOKEN_SECRET_VERSION:-}" ]]; then
  MATTERMOST_CICD_TOKEN_SECRET="$(access_secret_version "${MATTERMOST_CICD_TOKEN_SECRET_VERSION}" 2>/dev/null || true)"
fi
if [[ -n "${MATTERMOST_CICD_CHANNEL_ID_SECRET_VERSION:-}" ]]; then
  MATTERMOST_CICD_CHANNEL_ID="$(access_secret_version "${MATTERMOST_CICD_CHANNEL_ID_SECRET_VERSION}" 2>/dev/null || true)"
fi
export MATTERMOST_CICD_TOKEN_ID MATTERMOST_CICD_TOKEN_SECRET MATTERMOST_CICD_CHANNEL_ID

mattermost_post() {
  local text="$1"
  local root_id="${2:-}"
  local attach_log="${3:-false}"
  if [[ -z "${MATTERMOST_SITE_URL:-}" || -z "${MATTERMOST_CICD_TOKEN_SECRET:-}" || -z "${MATTERMOST_CICD_CHANNEL_ID:-}" ]]; then
    return 0
  fi

  local site_url="${MATTERMOST_SITE_URL%/}"
  local file_ids_json="[]"
  if [[ "${attach_log}" == "true" && -s "${deploy_log}" ]]; then
    local upload_response
    upload_response="$(curl -fsS \
      -H "Authorization: Bearer ${MATTERMOST_CICD_TOKEN_SECRET}" \
      -F "channel_id=${MATTERMOST_CICD_CHANNEL_ID}" \
      -F "files=@${deploy_log};filename=${deploy_rollout}.log" \
      "${site_url}/api/v4/files" 2>/dev/null || true)"
    if [[ -n "${upload_response}" ]]; then
      file_ids_json="$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(json.dumps([item["id"] for item in data.get("file_infos", []) if item.get("id")]))' <<<"${upload_response}" 2>/dev/null || printf '[]')"
    fi
  fi

  local response
  response="$(MATTERMOST_POST_TEXT="${text}" MATTERMOST_POST_ROOT_ID="${root_id}" MATTERMOST_POST_FILE_IDS="${file_ids_json}" python3 -c 'import json, os; payload = {"channel_id": os.environ["MATTERMOST_CICD_CHANNEL_ID"], "message": os.environ["MATTERMOST_POST_TEXT"]}; root_id = os.environ.get("MATTERMOST_POST_ROOT_ID", ""); file_ids = json.loads(os.environ.get("MATTERMOST_POST_FILE_IDS", "[]")); payload.update({"root_id": root_id} if root_id else {}); payload.update({"file_ids": file_ids} if file_ids else {}); print(json.dumps(payload))' | curl -fsS -X POST -H "Authorization: Bearer ${MATTERMOST_CICD_TOKEN_SECRET}" -H 'Content-Type: application/json' --data-binary @- "${site_url}/api/v4/posts" 2>/dev/null || true)"
  if [[ -n "${response}" ]]; then
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' <<<"${response}" 2>/dev/null || true
  fi
}

docker_artifact_link() {
  local image_ref="$1"
  local display_label="$2"
  local image_digest="${3:-}"
  local artifact_repo="${image_ref%:*}"
  local artifact_tag="${image_ref##*:}"
  local artifact_host="${artifact_repo%%/*}"
  local artifact_path="${artifact_repo#*/}"
  local artifact_location="${artifact_host%-docker.pkg.dev}"
  local artifact_project_id="${artifact_path%%/*}"
  local artifact_path_remainder="${artifact_path#*/}"
  local artifact_registry_repo="${artifact_path_remainder%%/*}"
  local artifact_name="${artifact_path_remainder#*/}"
  local artifact_selector="${artifact_tag}"
  if [[ -n "${image_digest}" && "${image_digest}" != "unknown-digest" ]]; then
    artifact_selector="${image_digest}"
  fi
  local artifact_url="https://console.cloud.google.com/artifacts/docker/${artifact_project_id}/${artifact_location}/${artifact_registry_repo}/${artifact_name}/${artifact_selector}?project=${artifact_project_id}"
  printf '[%s](%s)' "${display_label}" "${artifact_url}"
}

helm_chart_link() {
  local chart_version="$1"
  local chart_registry_path="${CHART_REPOSITORY#oci://}"
  docker_artifact_link "${chart_registry_path}/yourown-chat:${chart_version}" "yourown-chat:${chart_version}"
}

notify_deploy() {
  local state="$1"
  local exit_code="${2:-}"
  local duration_seconds="${3:-}"
  local icon="🔔"
  local state_label="${state}"
  case "${state}" in
    started)
      icon="🚀"
      state_label="started"
      ;;
    succeeded)
      icon="✅"
      state_label="succeeded"
      ;;
    failed)
      icon="❌"
      state_label="failed"
      ;;
  esac

  local release_url="https://console.cloud.google.com/deploy/delivery-pipelines/${deploy_region}/${deploy_pipeline}/releases/${deploy_release}?project=${TARGET_PROJECT_ID}"
  local rollout_url="${release_url}/rollouts/${deploy_rollout}"
  local text
  printf -v text '%s Deploy %s: **%s**\n\nRelease: [%s](%s)\nRollout: [%s](%s)\nTarget: `%s`' \
    "${icon}" \
    "${state_label}" \
    "${deploy_name}" \
    "${deploy_release}" \
    "${release_url}" \
    "${deploy_rollout}" \
    "${rollout_url}" \
    "${deploy_target}"

  if [[ -n "${exit_code}" ]]; then
    local prod_image_link
    local dev_image_link
    local chart_link
    prod_image_link="$(docker_artifact_link "${IMAGE_REPO}:${PROD_IMAGE_TAG:-${IMAGE_TAG}}" "mattermost:${PROD_IMAGE_TAG:-${IMAGE_TAG}}" "${PROD_IMAGE_DIGEST:-}")"
    dev_image_link="$(docker_artifact_link "${IMAGE_REPO}:${DEV_IMAGE_TAG}" "mattermost:${DEV_IMAGE_TAG}" "${DEV_IMAGE_DIGEST:-}")"
    chart_link="$(helm_chart_link "${CHART_VERSION}")"
    printf -v text '%s\n\nImages:\n%s\n%s\n\nHelm Chart: %s' \
      "${text}" \
      "${prod_image_link}" \
      "${dev_image_link}" \
      "${chart_link}"
    printf -v text '%s\nDuration: `%ss`  ' "${text}" "${duration_seconds}"
  fi

  local attach_log="false"
  if [[ -n "${exit_code}" ]]; then
    attach_log="true"
  fi
  mattermost_post "${text}" "${workflow_root_post_id}" "${attach_log}" >/dev/null || true
}

firewall_suffix="$(printf '%s' "${CLOUD_DEPLOY_ROLLOUT:-${CLOUD_DEPLOY_RELEASE:-manual}}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//; s/-$//' | cut -c1-32)"
if [[ -z "${firewall_suffix}" ]]; then
  firewall_suffix="manual"
fi
firewall_rule_name="yourown-chat-rke2-api-cd-${firewall_suffix}"

cleanup_firewall() {
  if [[ -n "${firewall_rule_name}" ]]; then
    gcloud compute firewall-rules delete "${firewall_rule_name}" \
      --project="${TARGET_PROJECT_ID}" \
      --quiet >/dev/null 2>&1 || true
  fi
}

deploy_result_uploaded=false
upload_deploy_result() {
  local result_status="$1"
  local failure_message="${2:-}"
  if [[ -z "${CLOUD_DEPLOY_OUTPUT_GCS_PATH:-}" ]]; then
    return 0
  fi

  DEPLOY_RESULT_STATUS="${result_status}" \
  DEPLOY_FAILURE_MESSAGE="${failure_message}" \
  DEPLOY_CHART_VERSION="${CHART_VERSION}" \
  DEPLOY_PROD_IMAGE_TAG="${PROD_IMAGE_TAG:-${IMAGE_TAG}}" \
  DEPLOY_DEV_IMAGE_TAG="${DEV_IMAGE_TAG}" \
    python3 - <<'PY' >/tmp/clouddeploy-deploy-results.json
import json
import os

payload = {
    "resultStatus": os.environ["DEPLOY_RESULT_STATUS"],
    "metadata": {
        "custom-target-source": "yourown-chat-rke2-helm",
        "chart-version": os.environ["DEPLOY_CHART_VERSION"],
        "prod-image-tag": os.environ["DEPLOY_PROD_IMAGE_TAG"],
        "dev-image-tag": os.environ["DEPLOY_DEV_IMAGE_TAG"],
    },
}
failure_message = os.environ.get("DEPLOY_FAILURE_MESSAGE", "")
if failure_message:
    payload["failureMessage"] = failure_message
print(json.dumps(payload))
PY

  gcloud storage cp /tmp/clouddeploy-deploy-results.json "${CLOUD_DEPLOY_OUTPUT_GCS_PATH%/}/results.json"
  deploy_result_uploaded=true
}

finish_deploy() {
  local exit_code="$?"
  local duration_seconds="$(( $(date -u +%s) - deploy_started_at ))"
  if [[ "${exit_code}" -ne 0 && "${deploy_result_uploaded}" != "true" ]]; then
    upload_deploy_result "FAILED" "deploy script exited with ${exit_code}" || true
  fi
  if [[ "${exit_code}" -eq 0 ]]; then
    notify_deploy "succeeded" "${exit_code}" "${duration_seconds}" || true
  else
    notify_deploy "failed" "${exit_code}" "${duration_seconds}" || true
  fi
  cleanup_firewall
  exit "${exit_code}"
}
trap finish_deploy EXIT

notify_deploy "started" || true
exec > >(tee -a "${deploy_log}") 2>&1

registry_host="${CHART_REPOSITORY#oci://}"
registry_host="${registry_host%%/*}"
gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "https://${registry_host}"

clouddeploy_ip="$(curl -fsSL https://api.ipify.org)"
gcloud compute firewall-rules create "${firewall_rule_name}" \
  --project="${TARGET_PROJECT_ID}" \
  --network="${RKE2_API_FIREWALL_NETWORK}" \
  --direction=INGRESS \
  --priority=900 \
  --action=ALLOW \
  --rules=tcp:6443 \
  --source-ranges="${clouddeploy_ip}/32" \
  --target-tags="${RKE2_API_TARGET_TAG}" \
  --description="Temporary Cloud Deploy access to yourown-chat RKE2 API for ${CLOUD_DEPLOY_RELEASE:-manual}"

gcloud secrets versions access latest \
  --project="${TARGET_PROJECT_ID}" \
  --secret="${KUBECONFIG_SECRET}" \
  >/tmp/kubeconfig.yaml

export KUBECONFIG=/tmp/kubeconfig.yaml
export CHART_REPOSITORY
export CHART_VERSION
export IMAGE_REPO
export IMAGE_TAG
export DEV_IMAGE_TAG
export PROD_IMAGE_TAG
export PROD_IMAGE_DIGEST
export DEV_IMAGE_DIGEST
export PROD_IMAGE_WITH_DIGEST
export DEV_IMAGE_WITH_DIGEST

echo "Deploying prod image ${PROD_IMAGE_TAG:-${IMAGE_TAG}} (${PROD_IMAGE_DIGEST:-unknown-digest})"
echo "Deploying dev image ${DEV_IMAGE_TAG} (${DEV_IMAGE_DIGEST:-unknown-digest})"

make deploy
upload_deploy_result "SUCCEEDED"
