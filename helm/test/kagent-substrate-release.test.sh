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
consumer_evidence="${repo_root}/helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json"
consumer_evidence_path="kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json"
consumer_evidence_sha="$(sha256_file "${consumer_evidence}")"
substrate_commit="$(jq -er '.source.commit' "${consumer_evidence}")"
substrate_version="$(jq -er '.charts.application.version' "${consumer_evidence}")"
substrate_application_ref="$(jq -er '.charts.application.ref' "${consumer_evidence}")"
substrate_crds_ref="$(jq -er '.charts.crds.ref' "${consumer_evidence}")"
d1="sha256:$(hex a 64)"
d2="sha256:$(hex b 64)"
d3="$(jq -er '.images.ateapi.digest' "${consumer_evidence}")"
d4="$(jq -er '.images.atecontroller.digest' "${consumer_evidence}")"
d5="sha256:$(hex e 64)"
d6="sha256:$(hex f 64)"
d7="sha256:$(hex 0 64)"
d8="$(jq -er '.images.atenet.digest' "${consumer_evidence}")"
d9="$(jq -er '.dependency_images.agentgateway.digest' "${consumer_evidence}")"
d10="$(jq -er '.images.releaseVerifier.digest' "${consumer_evidence}")"
d11="sha256:$(hex 6 64)"

contract="${work}/contract.json"
jq -n \
  --arg kc "${kagent_commit}" --arg sc "${substrate_commit}" \
  --arg d1 "${d1}" --arg d2 "${d2}" --arg d3 "${d3}" \
  --arg d4 "${d4}" --arg d5 "${d5}" --arg d6 "${d6}" \
  --arg d7 "${d7}" --arg d8 "${d8}" --arg d9 "${d9}" --arg d10 "${d10}" --arg d11 "${d11}" \
  --arg consumer_evidence_path "${consumer_evidence_path}" \
  --arg consumer_evidence_sha "${consumer_evidence_sha}" \
  --arg substrate_version "${substrate_version}" \
  --arg substrate_application_ref "${substrate_application_ref}" \
  --arg substrate_crds_ref "${substrate_crds_ref}" \
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
        artifact_schema_version: "3",
        charts: {
          application: {ref: ("oci://ghcr.io/pilprod/kagent/helm/kagent@" + $d5), version: "0.10.0"},
          crds: {ref: ("oci://ghcr.io/pilprod/kagent/helm/kagent-crds@" + $d6), version: "0.10.0"}
        },
        image_refs: {
          controller: ("ghcr.io/pilprod/kagent/controller@" + $d1),
          ui: ("ghcr.io/pilprod/kagent/ui@" + $d2)
        },
        runtime_images: {
          kagentHarness: ("ghcr.io/pilprod/kagent/golang-adk@" + $d7),
          codexHarness: ("ghcr.io/pilprod/kagent/codex-harness@" + $d11)
        }
      },
      substrate: {
        source_repository: "https://github.com/pilprod/substrate",
        source_commit: $sc,
        artifact_manifest_sha256: $consumer_evidence_sha,
        artifact_schema_version: "yourown.chat/substrate-semver-consumer-evidence/v1",
        artifact_manifest_path: $consumer_evidence_path,
        charts: {
          application: {ref: $substrate_application_ref, version: $substrate_version},
          crds: {ref: $substrate_crds_ref, version: $substrate_version}
        },
        image_refs: {
          ateapi: ("ghcr.io/pilprod/substrate/ateapi@" + $d3),
          atecontroller: ("ghcr.io/pilprod/substrate/atecontroller@" + $d4),
          atenet: ("ghcr.io/pilprod/substrate/atenet@" + $d8),
          agentgateway: ("ghcr.io/kagent-dev/substrate/agentgateway@" + $d9),
          releaseVerifier: ("ghcr.io/pilprod/substrate/substrate-release-verify@" + $d10)
        }
      }
    },
    compatibility: {
      kagent_rbac_create_false: true,
      kagent_obsolete_skills_init_removed: true,
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
        "ui.image.tag": ("0.10.0@" + $d2)
      },
      substrate: {
        "image.registry": "ghcr.io/pilprod/substrate",
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
grep -Fq 'Substrate pins use app-gcp consumer evidence; this was not a producer release asset.' "${output}"
grep -Fq 'external_broker_smoke_ready=false; required for local-agent-ready, not bootstrap' "${output}"
grep -Fq "runtime_images.kagentHarness=ghcr.io/pilprod/kagent/golang-adk@${d7}" "${output}"
grep -Fq "runtime_images.codexHarness=ghcr.io/pilprod/kagent/codex-harness@${d11}" "${output}"
! grep -Fq 'controller.agentImage' "${output}"
grep -Fq "image: \"ghcr.io/pilprod/substrate/substrate-release-verify@${d10}\"" "${output}"
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
! grep -Fq '  agentImage:' "${repo_root}/helm/kagent/kagent.values.yaml"
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
grep -Fq 'resource "kubernetes_network_policy_v1" "enrollment_admin_default_deny"' "${prerequisites}"
grep -Fq 'name      = "substrate-enrollment-admin-default-deny"' "${prerequisites}"
grep -Fq 'resource "kubernetes_network_policy_v1" "kagent_substrate_egress"' "${prerequisites}"
grep -Fq 'resource "kubernetes_network_policy_v1" "atenet_reviewed_egress"' "${prerequisites}"
grep -Fq 'resource "kubernetes_role_v1" "testbed_verifier"' "${prerequisites}"
grep -Fq 'cidr = "${var.cloudsql_private_ip}/32"' "${prerequisites}"
grep -Fq 'var.local_provider_only ||' "${prerequisites}"
grep -Fq 'for_each = var.bootstrap_enabled && !var.local_provider_only ? var.atenet_egress_destinations : {}' "${prerequisites}"
grep -Fq 'expected_derived_secret_contract' "${prerequisites}"
grep -Fq 'kubernetes_name   = "actor-id-ca-certs"' "${prerequisites}"

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

jq '.compatibility.kagent_obsolete_skills_init_removed = false' "${contract}" > "${work}/legacy-skills-init.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/legacy-skills-init.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/legacy-skills-init.yaml" 2>"${work}/legacy-skills-init.err"; then
  echo "release with the obsolete skills-init image unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'obsolete skills-init image is removed' "${work}/legacy-skills-init.err"

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

jq '.artifacts.kagent.artifact_schema_version = "2"' "${contract}" > "${work}/legacy-kagent-schema.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/legacy-kagent-schema.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/legacy-kagent-schema.yaml" 2>"${work}/legacy-kagent-schema.err"; then
  echo "legacy kagent evidence schema unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'kagent artifact must use release evidence schema 3' "${work}/legacy-kagent-schema.err"

jq 'del(.artifacts.kagent.runtime_images.codexHarness)' "${contract}" > "${work}/missing-codex-runtime.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/missing-codex-runtime.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/missing-codex-runtime.yaml" 2>"${work}/missing-codex-runtime.err"; then
  echo "kagent evidence without Codex runtime unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'runtime_images must contain exactly kagentHarness and codexHarness' "${work}/missing-codex-runtime.err"

jq --arg digest "${d11}" \
  '.artifacts.kagent.runtime_images.claudeHarness = ("ghcr.io/pilprod/kagent/claude-harness@" + $digest)' \
  "${contract}" > "${work}/extra-runtime.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/extra-runtime.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/extra-runtime.yaml" 2>"${work}/extra-runtime.err"; then
  echo "unexpected extra kagent runtime image unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'runtime_images must contain exactly kagentHarness and codexHarness' "${work}/extra-runtime.err"

jq --arg digest "${d7}" \
  '.artifacts.kagent.image_refs.agent = ("ghcr.io/pilprod/kagent/golang-adk@" + $digest)' \
  "${contract}" > "${work}/legacy-agent-image.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/legacy-agent-image.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/legacy-agent-image.yaml" 2>"${work}/legacy-agent-image.err"; then
  echo "legacy image_refs.agent unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'image_refs must contain exactly controller and ui' "${work}/legacy-agent-image.err"

jq --arg digest "${d7}" \
  '.helm_set_values.kagent["controller.agentImage.tag"] = ("0.10.0@" + $digest)' \
  "${contract}" > "${work}/legacy-agent-override.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/legacy-agent-override.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/legacy-agent-override.yaml" 2>"${work}/legacy-agent-override.err"; then
  echo "legacy controller.agentImage override unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'may contain only the exact immutable image' "${work}/legacy-agent-override.err"

mkdir -p "${work}/legacy-helm"
cp -R "${repo_root}/helm/kagent" "${work}/legacy-helm/kagent"
python3 - "${work}/legacy-helm/kagent/kagent.values.yaml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
path.write_text(
    source.replace(
        "controller:\n",
        'controller:\n  agentImage:\n    tag: ""\n',
        1,
    ),
    encoding="utf-8",
)
PY
legacy_values_sha="$(sha256_file "${work}/legacy-helm/kagent/kagent.values.yaml")"
jq --arg checksum "${legacy_values_sha}" \
  '.values_sha256["kagent/kagent.values.yaml"] = $checksum' \
  "${contract}" > "${work}/legacy-tracked-values.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/legacy-tracked-values.json")" \
  python3 "${renderer}" --source-root "${work}/legacy-helm" --output "${work}/legacy-tracked-values.yaml" 2>"${work}/legacy-tracked-values.err"; then
  echo "tracked legacy controller.agentImage unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'tracked kagent values must not define removed controller.agentImage' "${work}/legacy-tracked-values.err"

jq --arg digest "${d10}" \
  '.artifacts.substrate.image_refs.releaseVerifier = ("ghcr.io/elsewhere/substrate-release-verify@" + $digest)' \
  "${contract}" > "${work}/foreign-release-verifier.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/foreign-release-verifier.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/foreign-release-verifier.yaml" 2>"${work}/foreign-release-verifier.err"; then
  echo "foreign release verifier image unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'Substrate artifact fields must exactly match the checked-in consumer evidence' "${work}/foreign-release-verifier.err"

jq '.artifacts.substrate.artifact_manifest_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "${contract}" > "${work}/wrong-consumer-checksum.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/wrong-consumer-checksum.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/wrong-consumer-checksum.yaml" 2>"${work}/wrong-consumer-checksum.err"; then
  echo "Substrate consumer evidence with a mismatched checksum unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'consumer evidence does not match artifact_manifest_sha256' "${work}/wrong-consumer-checksum.err"

jq '.artifacts.substrate.artifact_schema_version = "yourown.chat/substrate-gke-preview/v1" | del(.artifacts.substrate.artifact_manifest_path)' \
  "${contract}" > "${work}/wrong-substrate-schema.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/wrong-substrate-schema.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/wrong-substrate-schema.yaml" 2>"${work}/wrong-substrate-schema.err"; then
  echo "legacy GKE preview evidence unexpectedly rendered as a Cloud Deploy artifact" >&2
  exit 1
fi
grep -Fq 'producer release schema v1 or checked-in semver consumer evidence' "${work}/wrong-substrate-schema.err"

jq '.artifacts.substrate.artifact_manifest_path = "kagent/evidence/substrate/v0.0.23/substrate-v0.0.23.consumer-evidence.json"' \
  "${contract}" > "${work}/missing-consumer-evidence.json"
if KAGENT_SUBSTRATE_RELEASE_JSON="$(<"${work}/missing-consumer-evidence.json")" \
  python3 "${renderer}" --source-root "${repo_root}/helm" --output "${work}/missing-consumer-evidence.yaml" 2>"${work}/missing-consumer-evidence.err"; then
  echo "Substrate consumer evidence with a missing checked-in manifest unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'consumer evidence must be a regular file' "${work}/missing-consumer-evidence.err"

printf 'kagent/Substrate immutable testbed render tests passed\n'
