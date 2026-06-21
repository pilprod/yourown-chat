#!/usr/bin/env bash
set -euo pipefail

source clouddeploy-release.env

apt-get update
apt-get install -y ca-certificates curl make python3

curl -fsSL -o /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

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
trap cleanup_firewall EXIT

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
