#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
renderer="${repo_root}/helm/kagent/render-release.py"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

hex() { printf '%*s' "$2" '' | tr ' ' "$1"; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

kagent_commit="$(hex 1 40)"
substrate_commit="$(hex 2 40)"
d1="sha256:$(hex a 64)"
d2="sha256:$(hex b 64)"
d3="sha256:$(hex c 64)"
d4="sha256:$(hex d 64)"
d5="sha256:$(hex e 64)"
d6="sha256:$(hex f 64)"
d7="sha256:$(hex 0 64)"
d8="sha256:$(hex 8 64)"
d9="sha256:$(hex 9 64)"
d10="sha256:$(hex 7 64)"

contract="${work}/contract.json"
jq -n \
  --arg kc "${kagent_commit}" --arg sc "${substrate_commit}" \
  --arg d1 "${d1}" --arg d2 "${d2}" --arg d3 "${d3}" \
  --arg d4 "${d4}" --arg d5 "${d5}" --arg d6 "${d6}" \
  --arg d7 "${d7}" --arg d8 "${d8}" --arg d9 "${d9}" --arg d10 "${d10}" \
  --arg kbase "$(sha256_file "${repo_root}/helm/kagent/kagent.values.yaml")" \
  --arg ktest "$(sha256_file "${repo_root}/helm/kagent/kagent-testbed.values.yaml")" \
  --arg sbase "$(sha256_file "${repo_root}/helm/kagent/substrate.values.yaml")" \
  --arg stest "$(sha256_file "${repo_root}/helm/kagent/substrate-testbed.values.yaml")" \
  '{
    bootstrap_enabled: true,
    release_enabled: true,
    native_secret_sync_ready: true,
    production_eligible: false,
    external_broker_smoke_ready: false,
    artifacts: {
      kagent: {
        source_repository: "https://github.com/pilprod/kagent",
        source_commit: $kc,
        artifact_manifest_sha256: ($kc + $kc[0:24]),
        artifact_schema_version: "yourown.chat/kagent-release/v1",
        charts: {
          application: {ref: ("oci://ghcr.io/pilprod/kagent/helm/kagent@" + $d5), version: "0.10.0"},
          crds: {ref: ("oci://ghcr.io/pilprod/kagent/helm/kagent-crds@" + $d6), version: "0.10.0"}
        },
        image_refs: {
          controller: ("ghcr.io/pilprod/kagent/controller@" + $d1),
          ui: ("ghcr.io/pilprod/kagent/ui@" + $d2),
          agent: ("ghcr.io/pilprod/kagent/golang-adk@" + $d7)
        }
      },
      substrate: {
        source_repository: "https://github.com/kagent-dev/substrate",
        source_commit: $sc,
        artifact_manifest_sha256: ($sc + $sc[0:24]),
        artifact_schema_version: "yourown.chat/substrate-release/v1",
        charts: {
          application: {ref: ("oci://ghcr.io/kagent-dev/substrate/helm/substrate@" + $d5), version: "0.1.0"},
          crds: {ref: ("oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds@" + $d6), version: "0.1.0"}
        },
        image_refs: {
          ateapi: ("ghcr.io/kagent-dev/substrate/ateapi@" + $d3),
          atecontroller: ("ghcr.io/kagent-dev/substrate/atecontroller@" + $d4),
          atenet: ("ghcr.io/kagent-dev/substrate/atenet@" + $d8),
          agentgateway: ("ghcr.io/kagent-dev/substrate/agentgateway@" + $d9),
          releaseVerifier: ("ghcr.io/kagent-dev/substrate/substrate-release-verify@" + $d10)
        }
      }
    },
    compatibility: {
      kagent_rbac_create_false: true,
      substrate_rbac_create_false: true,
      substrate_gateway_api_v1: true,
      substrate_go_module_commit: $sc
    },
    helm_set_values: {
      kagent: {
        "controller.image.registry": "ghcr.io/pilprod/kagent",
        "controller.image.repository": "controller",
        "controller.image.tag": ("0.10.0@" + $d1),
        "ui.image.registry": "ghcr.io/pilprod/kagent",
        "ui.image.repository": "ui",
        "ui.image.tag": ("0.10.0@" + $d2),
        "controller.agentImage.registry": "ghcr.io/pilprod/kagent",
        "controller.agentImage.repository": "golang-adk",
        "controller.agentImage.tag": ("0.10.0@" + $d7)
      },
      substrate: {
        "image.registry": "ghcr.io/kagent-dev/substrate",
        "image.digests.ateapi": $d3,
        "image.digests.atecontroller": $d4,
        "image.digests.atenet": $d8,
        "images.agentgateway": ("ghcr.io/kagent-dev/substrate/agentgateway@" + $d9)
      }
    },
    values_sha256: {
      "kagent/kagent.values.yaml": $kbase,
      "kagent/kagent-testbed.values.yaml": $ktest,
      "kagent/substrate.values.yaml": $sbase,
      "kagent/substrate-testbed.values.yaml": $stest
    },
    kagent_health_url: "http://kagent-controller.kagent-system.svc.cluster.local:8083/health",
    substrate_endpoint: "api.ate-system.svc.cluster.local:443",
    broker_server_name: "api.ate-system.svc",
    broker_service_name: "api",
    broker_service_port: 8443
  }' > "${contract}"

output="${work}/skaffold.yaml"
KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${contract}")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${output}"

grep -Fq 'name: kagent-substrate-testbed' "${output}"
grep -Fq 'name: substrate' "${output}"
grep -Fq 'namespace: ate-system' "${output}"
grep -Fq 'name: kagent' "${output}"
grep -Fq 'namespace: kagent-system' "${output}"
grep -Fq 'production_eligible=false' "${output}"
grep -Fq 'external_broker_smoke_ready=false; required for local-agent-ready, not bootstrap' "${output}"
grep -Fq "image: \"ghcr.io/kagent-dev/substrate/substrate-release-verify@${d10}\"" "${output}"
grep -Fq 'command: ["/ko-app/substrate-release-verify"]' "${output}"
grep -Fq -- '--require-gateway-programmed' "${output}"
grep -Fq -- '--kubernetes-token-file' "${output}"
grep -Fq -- '--substrate-ca-file' "${output}"
grep -Fq -- '--substrate-server-name' "${output}"
grep -Fq -- 'api.ate-system.svc' "${output}"
grep -Fq -- 'api.ate-system.svc.cluster.local:443' "${output}"
! grep -Fq -- '--broker-address' "${output}"
grep -Fq 'secretName: substrate-ate-controller-tls' "${repo_root}/helm/kagent/verify/testbed-job.yaml"
grep -Fq 'key: server-ca.pem' "${repo_root}/helm/kagent/verify/testbed-job.yaml"
grep -Fq 'defaultMode: 0444' "${repo_root}/helm/kagent/verify/testbed-job.yaml"
! grep -Fq 'client-credential-bundle.pem' "${repo_root}/helm/kagent/verify/testbed-job.yaml"
grep -Fq 'runAsUser: 65532' "${repo_root}/helm/kagent/verify/testbed-job.yaml"
grep -Fq 'runAsGroup: 65532' "${repo_root}/helm/kagent/verify/testbed-job.yaml"
grep -Fq "\"controller.image.tag\": \"0.10.0@${d1}\"" "${output}"
grep -Fq "\"ui.image.tag\": \"0.10.0@${d2}\"" "${output}"
! grep -Fq 'controller.image.digest' "${output}"
! grep -Fq 'ui.image.digest' "${output}"
[[ "$(grep -c '^  - name: kagent-substrate-' "${output}")" -eq 1 ]]
! grep -Eq 'kagent-substrate-(dev|prod)' "${output}"

grep -Fq 'kind: AgentgatewayParameters' "${repo_root}/helm/kagent/gateway/testbed-parameters.yaml"
grep -Fq 'apiVersion: agentgateway.dev/v1alpha1' "${repo_root}/helm/kagent/gateway/testbed-parameters.yaml"
grep -Fq 'cloud.google.com/l4-rbs: "enabled"' "${repo_root}/helm/kagent/gateway/testbed-parameters.yaml"
grep -Fq 'networking.gke.io/load-balancer-ip-addresses:' "${repo_root}/helm/kagent/gateway/testbed-parameters.yaml"
grep -Fq 'type: RuntimeDefault' "${repo_root}/helm/kagent/gateway/testbed-parameters.yaml"
! grep -Eq '^kind: (Gateway|TLSRoute)$' "${repo_root}/helm/kagent/gateway/testbed-parameters.yaml"
grep -Fq 'gateway:' "${repo_root}/helm/kagent/substrate.values.yaml"
grep -Fq 'enabled: true' "${repo_root}/helm/kagent/substrate.values.yaml"
app_outputs="${repo_root}/terraform/app-gcp/outputs.tfcomponent.hcl"
grep -Fq 'output "external_broker_smoke_required"' "${app_outputs}"
grep -Fq 'value       = !var.kagent_substrate_delivery.external_broker_smoke_ready' "${app_outputs}"
grep -Fq 'output "kagent_local_agent_ready"' "${app_outputs}"
grep -Fq 'var.kagent_substrate_delivery.external_broker_smoke_ready' "${app_outputs}"

prerequisites="${repo_root}/terraform/app-gcp/modules/substrate-prerequisites/main.tf"
grep -Fq 'resource "kubernetes_namespace_v1" "substrate"' "${prerequisites}"
grep -Fq 'resource "helm_release" "substrate_crds"' "${prerequisites}"
grep -Fq 'prevent_destroy = true' "${prerequisites}"
grep -Fq 'resource "kubernetes_network_policy_v1" "substrate_api_external_egress"' "${prerequisites}"
grep -Fq 'resource "kubernetes_network_policy_v1" "substrate_controller_api_egress"' "${prerequisites}"
grep -Fq 'resource "kubernetes_network_policy_v1" "kagent_substrate_egress"' "${prerequisites}"
grep -Fq 'resource "kubernetes_network_policy_v1" "atenet_reviewed_egress"' "${prerequisites}"
grep -Fq 'resource "kubernetes_role_v1" "testbed_verifier"' "${prerequisites}"
grep -Fq 'cidr = "${var.cloudsql_private_ip}/32"' "${prerequisites}"
grep -Fq 'condition     = length(var.atenet_egress_destinations) > 0' "${prerequisites}"

kagent_fixture="${repo_root}/helm/test/fixtures/kagent-image-contract"
rendered_images="${work}/kagent-images.yaml"
helm template kagent-image-contract "${kagent_fixture}" \
  --set-string controller.image.registry=ghcr.io/pilprod/kagent \
  --set-string controller.image.repository=controller \
  --set-string "controller.image.tag=0.10.0@${d1}" \
  --set-string ui.image.registry=ghcr.io/pilprod/kagent \
  --set-string ui.image.repository=ui \
  --set-string "ui.image.tag=0.10.0@${d2}" > "${rendered_images}"
grep -Fq "image: ghcr.io/pilprod/kagent/controller:0.10.0@${d1}" "${rendered_images}"
grep -Fq "image: ghcr.io/pilprod/kagent/ui:0.10.0@${d2}" "${rendered_images}"

jq '.production_eligible = true' "${contract}" > "${work}/bad.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/bad.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/bad.yaml" 2>"${work}/bad.err"; then
  echo "production-eligible contract unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'production_eligible=false' "${work}/bad.err"

jq 'del(.external_broker_smoke_ready)' "${contract}" > "${work}/missing-smoke-status.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/missing-smoke-status.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/missing-smoke-status.yaml" 2>"${work}/missing-smoke-status.err"; then
  echo "release without explicit external Broker smoke status unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'external_broker_smoke_ready must be an explicit boolean' "${work}/missing-smoke-status.err"

jq '.compatibility.substrate_gateway_api_v1 = false' "${contract}" > "${work}/gateway-api-beta.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/gateway-api-beta.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/gateway-api-beta.yaml" 2>"${work}/gateway-api-beta.err"; then
  echo "Substrate artifact without Gateway API v1 proof unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'Gateway and TLSRoute gateway.networking.k8s.io/v1' "${work}/gateway-api-beta.err"

jq '.helm_set_values.kagent["rbac.create"] = "true"' "${contract}" > "${work}/structural-override.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/structural-override.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/structural-override.yaml" 2>"${work}/structural-override.err"; then
  echo "structural Helm override unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'may contain only the exact immutable image' "${work}/structural-override.err"

jq --arg digest "${d1}" \
  'del(.helm_set_values.kagent["controller.image.tag"]) | .helm_set_values.kagent["controller.image.digest"] = $digest' \
  "${contract}" > "${work}/ignored-digest-key.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/ignored-digest-key.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/ignored-digest-key.yaml" 2>"${work}/ignored-digest-key.err"; then
  echo "ignored kagent digest key unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'may contain only the exact immutable image' "${work}/ignored-digest-key.err"

jq --arg digest "${d10}" \
  '.artifacts.substrate.image_refs.releaseVerifier = ("ghcr.io/elsewhere/substrate-release-verify@" + $digest)' \
  "${contract}" > "${work}/foreign-release-verifier.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/foreign-release-verifier.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/foreign-release-verifier.yaml" 2>"${work}/foreign-release-verifier.err"; then
  echo "foreign release verifier image unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'releaseVerifier must be the immutable substrate-release-verify image from the artifact registry' "${work}/foreign-release-verifier.err"

printf 'kagent/Substrate immutable testbed render tests passed\n'
