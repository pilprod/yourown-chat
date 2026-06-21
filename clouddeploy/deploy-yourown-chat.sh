#!/usr/bin/env bash
set -euo pipefail

source clouddeploy-release.env

apk add --no-cache bash ca-certificates curl helm kubectl make python3

registry_host="${CHART_REPOSITORY#oci://}"
registry_host="${registry_host%%/*}"
gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "https://${registry_host}"

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
  if [[ "${exit_code}" -ne 0 && "${deploy_result_uploaded}" != "true" ]]; then
    upload_deploy_result "FAILED" "deploy script exited with ${exit_code}" || true
  fi
  cleanup_firewall
  exit "${exit_code}"
}
trap finish_deploy EXIT

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
