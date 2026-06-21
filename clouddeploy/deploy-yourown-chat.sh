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
cicd_workflow_id="${CICD_WORKFLOW_ID:-${deploy_pipeline}|${deploy_release}}"
cicd_workflow_name="${CICD_WORKFLOW_NAME:-yourown-chat deploy}"
cicd_project_label="${CICD_PROJECT_LABEL:-yourown-chat}"
cicd_project_url="${CICD_PROJECT_URL:-}"
cicd_tag_label="${CICD_TAG_LABEL:-${CHART_VERSION}}"
cicd_tag_url="${CICD_TAG_URL:-}"
cicd_commit_label="${CICD_COMMIT_LABEL:-unknown-sha}"
cicd_commit_url="${CICD_COMMIT_URL:-}"
cicd_build_id="${CICD_BUILD_ID:-}"
cicd_build_url="${CICD_BUILD_URL:-}"

docker_artifact_json() {
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
  ARTIFACT_LABEL="${display_label}" ARTIFACT_URL="${artifact_url}" ARTIFACT_REF="${image_ref}" \
    python3 -c 'import json, os; print(json.dumps({"label": os.environ["ARTIFACT_LABEL"], "url": os.environ["ARTIFACT_URL"], "ref": os.environ["ARTIFACT_REF"]}, separators=(",", ":")))'
}

helm_chart_json() {
  local chart_version="$1"
  local chart_registry_path="${CHART_REPOSITORY#oci://}"
  docker_artifact_json "${chart_registry_path}/yourown-chat:${chart_version}" "yourown-chat:${chart_version}"
}

emit_deploy_report() {
  local state="$1"
  local exit_code="${2:-}"
  local duration_seconds="${3:-}"
  local release_url="https://console.cloud.google.com/deploy/delivery-pipelines/${deploy_region}/${deploy_pipeline}/releases/${deploy_release}?project=${TARGET_PROJECT_ID}"
  local rollout_url="${release_url}/rollouts/${deploy_rollout}"
  local artifacts_json=""
  if [[ -n "${exit_code}" ]]; then
    local prod_image_link
    local dev_image_link
    local chart_link
    prod_image_link="$(docker_artifact_json "${IMAGE_REPO}:${PROD_IMAGE_TAG:-${IMAGE_TAG}}" "mattermost:${PROD_IMAGE_TAG:-${IMAGE_TAG}}" "${PROD_IMAGE_DIGEST:-}")"
    dev_image_link="$(docker_artifact_json "${IMAGE_REPO}:${DEV_IMAGE_TAG}" "mattermost:${DEV_IMAGE_TAG}" "${DEV_IMAGE_DIGEST:-}")"
    chart_link="$(helm_chart_json "${CHART_VERSION}")"
    CICD_IMAGE_PROD="${prod_image_link}" \
    CICD_IMAGE_DEV="${dev_image_link}" \
    CICD_CHART="${chart_link}" \
      python3 -c 'import json, os; payload = {"images": [json.loads(os.environ["CICD_IMAGE_PROD"]), json.loads(os.environ["CICD_IMAGE_DEV"])], "chart": json.loads(os.environ["CICD_CHART"])}; print(json.dumps(payload, separators=(",", ":")))' >/tmp/yourown-chat-deploy-artifacts.json
    artifacts_json="$(cat /tmp/yourown-chat-deploy-artifacts.json)"
  fi
  CICD_REPORT_WORKFLOW_ID="${cicd_workflow_id}" \
  CICD_REPORT_WORKFLOW_NAME="${cicd_workflow_name}" \
  CICD_REPORT_STATE="${state}" \
  CICD_REPORT_NAME="${deploy_name}" \
  CICD_REPORT_PROJECT_LABEL="${cicd_project_label}" \
  CICD_REPORT_PROJECT_URL="${cicd_project_url}" \
  CICD_REPORT_TAG_LABEL="${cicd_tag_label}" \
  CICD_REPORT_TAG_URL="${cicd_tag_url}" \
  CICD_REPORT_COMMIT_LABEL="${cicd_commit_label}" \
  CICD_REPORT_COMMIT_URL="${cicd_commit_url}" \
  CICD_REPORT_BUILD_ID="${cicd_build_id}" \
  CICD_REPORT_BUILD_URL="${cicd_build_url}" \
  CICD_REPORT_RELEASE="${deploy_release}" \
  CICD_REPORT_RELEASE_URL="${release_url}" \
  CICD_REPORT_ROLLOUT="${deploy_rollout}" \
  CICD_REPORT_ROLLOUT_URL="${rollout_url}" \
  CICD_REPORT_TARGET="${deploy_target}" \
  CICD_REPORT_EXIT_CODE="${exit_code}" \
  CICD_REPORT_DURATION_SECONDS="${duration_seconds}" \
  CICD_REPORT_ARTIFACTS_JSON="${artifacts_json}" \
    python3 -c 'import json, os; payload = {"workflow_id": os.environ["CICD_REPORT_WORKFLOW_ID"], "workflow_name": os.environ["CICD_REPORT_WORKFLOW_NAME"], "stage": "deploy", "state": os.environ["CICD_REPORT_STATE"], "name": os.environ["CICD_REPORT_NAME"], "project": {"label": os.environ["CICD_REPORT_PROJECT_LABEL"], "url": os.environ.get("CICD_REPORT_PROJECT_URL", "")}, "tag": {"label": os.environ["CICD_REPORT_TAG_LABEL"], "url": os.environ.get("CICD_REPORT_TAG_URL", "")}, "commit": {"label": os.environ["CICD_REPORT_COMMIT_LABEL"], "url": os.environ.get("CICD_REPORT_COMMIT_URL", "")}, "release_id": os.environ["CICD_REPORT_RELEASE"], "rollout_id": os.environ["CICD_REPORT_ROLLOUT"], "release": {"label": os.environ["CICD_REPORT_RELEASE"], "url": os.environ["CICD_REPORT_RELEASE_URL"]}, "rollout": {"label": os.environ["CICD_REPORT_ROLLOUT"], "url": os.environ["CICD_REPORT_ROLLOUT_URL"]}, "target": os.environ["CICD_REPORT_TARGET"]}; payload.update({"build_id": os.environ["CICD_REPORT_BUILD_ID"], "build": {"label": os.environ["CICD_REPORT_BUILD_ID"], "url": os.environ.get("CICD_REPORT_BUILD_URL", "")}} if os.environ.get("CICD_REPORT_BUILD_ID") else {}); payload.update({"exit_code": int(os.environ["CICD_REPORT_EXIT_CODE"])} if os.environ.get("CICD_REPORT_EXIT_CODE") else {}); payload.update({"duration_seconds": int(os.environ["CICD_REPORT_DURATION_SECONDS"])} if os.environ.get("CICD_REPORT_DURATION_SECONDS") else {}); artifacts = json.loads(os.environ.get("CICD_REPORT_ARTIFACTS_JSON") or "{}"); payload.update({"artifacts": artifacts} if artifacts else {}); print("CICD_REPORT " + json.dumps(payload, separators=(",", ":")))'
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
    emit_deploy_report "succeeded" "${exit_code}" "${duration_seconds}" || true
  else
    emit_deploy_report "failed" "${exit_code}" "${duration_seconds}" || true
  fi
  cleanup_firewall
  exit "${exit_code}"
}
trap finish_deploy EXIT

emit_deploy_report "started" || true
echo "Cloud Deploy deploy release=${deploy_release} rollout=${deploy_rollout} target=${deploy_target}"

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
