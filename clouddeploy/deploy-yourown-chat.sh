#!/usr/bin/env bash
set -euo pipefail

source clouddeploy-release.env

apk add --no-cache bash ca-certificates curl helm kubectl make openssh-client python3

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
  local rollout_url="https://console.cloud.google.com/deploy/delivery-pipelines/${deploy_region}/${deploy_pipeline}/releases/${deploy_release}/rollouts/${deploy_rollout}?project=${TARGET_PROJECT_ID}"
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

RKE2_API_TUNNEL_LOCAL_PORT="${RKE2_API_TUNNEL_LOCAL_PORT:-16443}"
RKE2_API_TUNNEL_LOG="${RKE2_API_TUNNEL_LOG:-/tmp/yourown-chat-rke2-api-iap-tunnel.log}"
RKE2_API_TUNNEL_PID=""

cleanup_tunnel() {
  if [[ -n "${RKE2_API_TUNNEL_PID}" ]] && kill -0 "${RKE2_API_TUNNEL_PID}" 2>/dev/null; then
    kill "${RKE2_API_TUNNEL_PID}" >/dev/null 2>&1 || true
    wait "${RKE2_API_TUNNEL_PID}" >/dev/null 2>&1 || true
  fi
}

require_ssh_client() {
  if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh client is required for the RKE2 IAP tunnel but was not found in PATH." >&2
    return 1
  fi
}

show_tunnel_log() {
  if [[ -s "${RKE2_API_TUNNEL_LOG}" ]]; then
    sed 's/^/[tunnel] /' "${RKE2_API_TUNNEL_LOG}" >&2 || true
  else
    echo "[tunnel] tunnel log is empty" >&2
  fi
}

wait_for_rke2_api() {
  local attempts="${RKE2_API_READY_ATTEMPTS:-60}"
  local interval_seconds="${RKE2_API_READY_INTERVAL_SECONDS:-5}"
  local request_timeout="${RKE2_API_READY_REQUEST_TIMEOUT:-10s}"
  local server_url=""
  local last_error
  last_error="$(mktemp)"

  server_url="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [[ -n "${server_url}" ]]; then
    echo "Waiting for RKE2 API at ${server_url}"
  fi

  for attempt in $(seq 1 "${attempts}"); do
    if [[ -n "${RKE2_API_TUNNEL_PID}" ]] && ! kill -0 "${RKE2_API_TUNNEL_PID}" 2>/dev/null; then
      echo "RKE2 API IAP tunnel exited before the API became ready." >&2
      show_tunnel_log
      rm -f "${last_error}"
      return 1
    fi

    if kubectl --request-timeout="${request_timeout}" get --raw=/readyz >/dev/null 2>"${last_error}"; then
      rm -f "${last_error}"
      return 0
    fi

    echo "Waiting for RKE2 API (${attempt}/${attempts})..."
    if [[ "${attempt}" == "1" || "${attempt}" == "${attempts}" || $((attempt % 12)) -eq 0 ]]; then
      sed 's/^/[kubectl] /' "${last_error}" >&2 || true
    fi
    sleep "${interval_seconds}"
  done

  echo "Timed out waiting for RKE2 API." >&2
  echo "Last kubectl error:" >&2
  sed 's/^/[kubectl] /' "${last_error}" >&2 || true
  echo "Tunnel log:" >&2
  show_tunnel_log
  rm -f "${last_error}"
  return 1
}

run_make_deploy_with_retry() {
  local attempts="${RKE2_DEPLOY_ATTEMPTS:-3}"
  local interval_seconds="${RKE2_DEPLOY_RETRY_INTERVAL_SECONDS:-10}"

  for attempt in $(seq 1 "${attempts}"); do
    if [[ -n "${RKE2_API_TUNNEL_PID}" ]] && ! kill -0 "${RKE2_API_TUNNEL_PID}" 2>/dev/null; then
      echo "RKE2 API IAP tunnel exited before deploy attempt ${attempt}." >&2
      show_tunnel_log
      return 1
    fi

    wait_for_rke2_api
    if make deploy; then
      return 0
    fi

    if [[ "${attempt}" == "${attempts}" ]]; then
      echo "make deploy failed after ${attempts} attempts." >&2
      show_tunnel_log
      return 1
    fi

    echo "make deploy failed (${attempt}/${attempts}); waiting for RKE2 API before retry..." >&2
    wait_for_rke2_api || true
    sleep "${interval_seconds}"
  done
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
  cleanup_tunnel
  exit "${exit_code}"
}
trap finish_deploy EXIT

emit_deploy_report "started" || true
echo "Cloud Deploy deploy release=${deploy_release} rollout=${deploy_rollout} target=${deploy_target}"

registry_host="${CHART_REPOSITORY#oci://}"
registry_host="${registry_host%%/*}"
gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "https://${registry_host}"

gcloud secrets versions access latest \
  --project="${TARGET_PROJECT_ID}" \
  --secret="${KUBECONFIG_SECRET}" \
  >/tmp/kubeconfig.yaml

export KUBECONFIG=/tmp/kubeconfig.yaml
if [[ -z "${RKE2_API_TUNNEL_INSTANCE:-}" || -z "${RKE2_API_TUNNEL_ZONE:-}" ]]; then
  echo "RKE2_API_TUNNEL_INSTANCE and RKE2_API_TUNNEL_ZONE are required" >&2
  exit 1
fi
require_ssh_client

: >"${RKE2_API_TUNNEL_LOG}"
echo "Opening RKE2 API IAP tunnel: instance=${RKE2_API_TUNNEL_INSTANCE}, zone=${RKE2_API_TUNNEL_ZONE}, local=https://127.0.0.1:${RKE2_API_TUNNEL_LOCAL_PORT}"
gcloud compute ssh "${RKE2_API_TUNNEL_INSTANCE}" \
  --project="${TARGET_PROJECT_ID}" \
  --zone="${RKE2_API_TUNNEL_ZONE}" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag="-N" \
  --ssh-flag="-o ExitOnForwardFailure=yes" \
  --ssh-flag="-o ServerAliveInterval=15" \
  --ssh-flag="-o ServerAliveCountMax=4" \
  --ssh-flag="-L 127.0.0.1:${RKE2_API_TUNNEL_LOCAL_PORT}:127.0.0.1:6443" \
  >"${RKE2_API_TUNNEL_LOG}" 2>&1 </dev/null &
RKE2_API_TUNNEL_PID="$!"

cluster_name="$(kubectl config view --raw -o jsonpath='{.contexts[0].context.cluster}')"
kubectl config set-cluster "${cluster_name}" --server="https://127.0.0.1:${RKE2_API_TUNNEL_LOCAL_PORT}" >/dev/null
kubectl config unset "clusters.${cluster_name}.certificate-authority" >/dev/null 2>&1 || true
kubectl config unset "clusters.${cluster_name}.certificate-authority-data" >/dev/null 2>&1 || true
kubectl config set-cluster "${cluster_name}" --insecure-skip-tls-verify=true >/dev/null
export GODEBUG="${GODEBUG:+${GODEBUG},}http2client=0"
wait_for_rke2_api

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

run_make_deploy_with_retry
upload_deploy_result "SUCCEEDED"
