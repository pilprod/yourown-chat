#!/bin/sh
set -eu

: "${CLOUD_DEPLOY_RELEASE:?Cloud Deploy release ID is required}"

cluster_name="${GKE_CLUSTER##*/}"
cluster_parent="${GKE_CLUSTER%/clusters/*}"
cluster_location="${cluster_parent##*/}"
cluster_project_path="${cluster_parent%/locations/*}"
cluster_project="${cluster_project_path##*/}"

gcloud container clusters get-credentials "${cluster_name}" \
  --project "${cluster_project}" \
  --location "${cluster_location}"

attestation="$(kubectl \
  --namespace ate-system \
  get configmap/kagent-production-promotion-gate \
  -o 'go-template={{index .data "external_broker_smoke_ready"}}|{{index .data "cloud_deploy_release"}}')"

if [ "${attestation}" != "true|${CLOUD_DEPLOY_RELEASE}" ]; then
  echo "Production rollout blocked: this Cloud Deploy release has no external Agent Host TLS+gRPC smoke attestation." >&2
  exit 1
fi

echo "Production rollout admitted by the Terraform-managed external Broker smoke attestation."
