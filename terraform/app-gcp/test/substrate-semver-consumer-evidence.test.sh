#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source_manifest="${repo_root}/helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json"
source_checksum="${source_manifest}.sha256"
source_module="${repo_root}/helm/kagent/substrate_consumer_evidence.py"
source_renderer="${repo_root}/terraform/app-gcp/scripts/render-substrate-semver-consumer-pin-fragment.py"
kagent_evidence_renderer="${repo_root}/terraform/app-gcp/scripts/render-kagent-release-evidence-binding.py"
kagent_evidence_fixture_writer="${repo_root}/helm/test/write-kagent-schema3-evidence-fixture.py"
kagent_scan_evaluator="${repo_root}/terraform/app-gcp/modules/kagent-preview-publisher/scripts/evaluate-scan-vulnerabilities.sh"
stack_variables="${repo_root}/terraform/app-gcp/variables.tfcomponent.hcl"

fail() {
  printf 'Substrate semver consumer evidence test failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local path="$1"
  local literal="$2"
  if ! grep -Fq -- "${literal}" "${path}"; then
    sed -n '1,160p' "${path}" >&2
    fail "${path} is missing: ${literal}"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

for command_name in git jq python3 terraform; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

expected_sha="$(sha256_file "${source_manifest}")"
[[ "$(<"${source_checksum}")" == "${expected_sha}  substrate-v0.0.22.consumer-evidence.json" ]] || \
  fail "checked-in v0.0.22 checksum is stale"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fixture_repo="${work}/repository"
fixture_manifest="${fixture_repo}/helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json"
fixture_renderer="${fixture_repo}/terraform/app-gcp/scripts/render-substrate-semver-consumer-pin-fragment.py"
mkdir -p "$(dirname "${fixture_manifest}")" "$(dirname "${fixture_renderer}")"
cp "${source_manifest}" "${fixture_manifest}"
cp "${source_checksum}" "${fixture_manifest}.sha256"
cp "${source_module}" "${fixture_repo}/helm/kagent/substrate_consumer_evidence.py"
cp "${source_renderer}" "${fixture_renderer}"
chmod +x "${fixture_renderer}"
git -C "${fixture_repo}" init -q

output="${work}/fragment.hcl"
errors="${work}/fragment.err"
"${fixture_renderer}" "${fixture_manifest}" >"${output}" 2>"${errors}" || \
  fail "canonical consumer evidence was rejected"
require_literal "${output}" '# INCOMPLETE Substrate-only handoff; this is not a full kagent_substrate_delivery value.'
require_literal "${output}" '# Consumer-owned public semver evidence; this was not emitted as a producer release asset.'
require_literal "${output}" 'source_commit            = "e9ed68e587b56df2aa2a7f0267a744598c4d48b4"'
require_literal "${output}" 'artifact_manifest_sha256 = "987d123a8105cbf791e4aa73be7bbe28e2cca0e99ad71b29e7b7f81a7038dd80"'
require_literal "${output}" 'artifact_schema_version  = "yourown.chat/substrate-semver-consumer-evidence/v1"'
require_literal "${output}" 'artifact_manifest_path   = "kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json"'
require_literal "${output}" 'ref     = "oci://ghcr.io/pilprod/substrate/helm/substrate@sha256:bb166a3170cfa5e9ea655497d2e255fc0fa68cf5476f46b9ec25332c9cd1a49a"'
require_literal "${output}" 'ref     = "oci://ghcr.io/pilprod/substrate/helm/substrate-crds@sha256:816f98e1b5f0b6ba4655f185ed984b7b4a09e7ab6cab16ba0d3ab05bfa313059"'
require_literal "${output}" 'agentgateway    = "ghcr.io/kagent-dev/substrate/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429"'
require_literal "${errors}" 'independent reviewed kagent evidence and all bootstrap gates remain required'

wrapper="${work}/fragment.tf"
{
  printf 'locals {\n'
  sed -e '/^$/b' -e 's/^/  /' "${output}"
  printf '}\n'
} >"${wrapper}"
terraform fmt -check "${wrapper}" >/dev/null || fail "rendered HCL fragment is not terraform-fmt clean"

refresh_checksum() {
  printf '%s  substrate-v0.0.22.consumer-evidence.json\n' "$(sha256_file "${fixture_manifest}")" >"${fixture_manifest}.sha256"
}

restore_manifest() {
  cp "${source_manifest}" "${fixture_manifest}"
  cp "${source_checksum}" "${fixture_manifest}.sha256"
}

mutate_manifest() {
  local filter="$1"
  jq "${filter}" "${fixture_manifest}" >"${work}/replacement.json"
  mv "${work}/replacement.json" "${fixture_manifest}"
  refresh_checksum
}

expect_failure() {
  local label="$1"
  local expected="$2"
  local stdout="${work}/${label}.out"
  local stderr="${work}/${label}.err"
  if "${fixture_renderer}" "${fixture_manifest}" >"${stdout}" 2>"${stderr}"; then
    fail "${label} unexpectedly succeeded"
  fi
  [[ ! -s "${stdout}" ]] || fail "${label} emitted a partial fragment"
  require_literal "${stderr}" "${expected}"
}

printf 'bad checksum\n' >"${fixture_manifest}.sha256"
expect_failure stale-checksum 'consumer evidence does not match its checked-in checksum'

restore_manifest
mutate_manifest '.unexpected = true'
expect_failure unknown-key 'consumer evidence must contain exactly'

restore_manifest
mutate_manifest '.evidence.producer_release_asset = true'
expect_failure producer-claim 'not a producer release asset'

restore_manifest
mutate_manifest '.images.ateapi.digest = .images.atecontroller.digest'
expect_failure mismatched-image 'image ateapi ref must exactly match its registry, repository and digest'

restore_manifest
mutate_manifest '.dependency_images.agentgateway.ref = "ghcr.io/kagent-dev/substrate/agentgateway@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_failure mismatched-agentgateway 'agentgateway ref must match the reviewed upstream dependency and digest'

restore_manifest
mutate_manifest '.charts.application.version = "0.0.23"'
expect_failure mismatched-chart-version 'chart application release name and version must match release_tag'

restore_manifest
mutate_manifest '.helm_set_values["image.digests.atenet"] = .images.ateapi.digest'
expect_failure mismatched-helm-values 'Helm set values must exactly map the chart-consumed image pins'

restore_manifest
duplicate="${work}/duplicate.json"
sed '1a\
  "schema_version": "yourown.chat/substrate-semver-consumer-evidence/v1",' "${fixture_manifest}" >"${duplicate}"
mv "${duplicate}" "${fixture_manifest}"
refresh_checksum
expect_failure duplicate-json 'duplicate JSON key: schema_version'

restore_manifest
outside="${work}/substrate-v0.0.22.consumer-evidence.json"
cp "${fixture_manifest}" "${outside}"
cp "${fixture_manifest}.sha256" "${outside}.sha256"
if "${fixture_renderer}" "${outside}" >"${work}/outside.out" 2>"${work}/outside.err"; then
  fail "renderer accepted consumer evidence outside the canonical Helm evidence directory"
fi
[[ ! -s "${work}/outside.out" ]] || fail "outside-path failure emitted a partial fragment"
require_literal "${work}/outside.err" 'consumer evidence must be below the Helm source root'

# Exercise the exact Stack variable validation independently of HCP Terraform.
# Bootstrap installs the cluster-wide CRD chart before the Cloud Deploy renderer
# ever runs, so the Stack input itself must reject every drift from the
# checked-in consumer record.
gate_module="${work}/bootstrap-gate"
mkdir -p "${gate_module}"
sed -n \
  '/^variable "kagent_substrate_delivery" {/,/^variable "additional_cloudsql_connection_secret_ids" {/p' \
  "${stack_variables}" | sed '$d' >"${gate_module}/main.tf"
cat >>"${gate_module}/main.tf" <<'HCL'

output "bootstrap_enabled" {
  value = var.kagent_substrate_delivery.bootstrap_enabled
}
HCL

valid_contract="${work}/valid-bootstrap-contract.json"
kagent_evidence="${work}/kagent-release-evidence.json"
kagent_application_digest="sha256:1111111111111111111111111111111111111111111111111111111111111111"
kagent_crds_digest="sha256:2222222222222222222222222222222222222222222222222222222222222222"
kagent_controller_digest="sha256:3333333333333333333333333333333333333333333333333333333333333333"
kagent_ui_digest="sha256:4444444444444444444444444444444444444444444444444444444444444444"
kagent_harness_digest="sha256:5555555555555555555555555555555555555555555555555555555555555555"
codex_harness_digest="sha256:6666666666666666666666666666666666666666666666666666666666666666"
python3 "${kagent_evidence_fixture_writer}" \
  --output "${kagent_evidence}" \
  --controller "${kagent_controller_digest}" \
  --ui "${kagent_ui_digest}" \
  --application "${kagent_application_digest}" \
  --crds "${kagent_crds_digest}" \
  --kagent-harness "${kagent_harness_digest}" \
  --codex-harness "${codex_harness_digest}"
kagent_evidence_sha="$(sha256_file "${kagent_evidence}")"
kagent_evidence_uri="gs://yourown-chat-kagent-preview-evidence-europe-west3/kagent/0.0.0-external-slot.kap.5/00000000-0000-4000-8000-000000000001/release-evidence.json#1"
fake_gcloud="${work}/gcloud"
cat >"${fake_gcloud}" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

if [[ "$#" -ne 3 || "$1" != "storage" || "$2" != "cat" || "$3" != "${KAGENT_TEST_EVIDENCE_URI:?}" ]]; then
  printf 'unexpected gcloud storage cat request\n' >&2
  exit 41
fi
/bin/cat "${KAGENT_TEST_EVIDENCE_FILE:?}"
EOF
chmod +x "${fake_gcloud}"
export KAGENT_TEST_EVIDENCE_FILE="${kagent_evidence}"
export KAGENT_TEST_EVIDENCE_URI="${kagent_evidence_uri}"
reviewed_evaluator_sha="$(
  PYTHONPATH="${repo_root}/helm/kagent" python3 -c \
    'from kagent_release_evidence import SCAN_POLICY_EVALUATOR_SHA256; print(SCAN_POLICY_EVALUATOR_SHA256)'
)"
[[ "${reviewed_evaluator_sha}" == "$(sha256_file "${kagent_scan_evaluator}")" ]] || \
  fail "consumer scan evaluator pin drifted from the reviewed publisher implementation"
jq -n \
  --arg manifest_sha "${expected_sha}" \
  --arg manifest_path 'kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json' \
  --arg kagent_evidence_sha "${kagent_evidence_sha}" \
  --arg kagent_evidence_uri "${kagent_evidence_uri}" \
  --rawfile kagent_evidence "${kagent_evidence}" \
  --slurpfile evidence "${source_manifest}" \
  '{
    bootstrap_enabled: true,
    release_enabled: false,
    production_eligible: false,
    local_provider_only: true,
    native_secret_sync_ready: false,
    crd_ownership_ready: false,
    controller_namespace_handoff_ready: false,
    external_broker_smoke_ready: false,
    kagent_release_evidence: {
      uri: $kagent_evidence_uri,
      manifest_json: $kagent_evidence
    },
    artifacts: {
      kagent: {
        source_repository: "https://github.com/pilprod/kagent",
        source_commit: "547cfe605940005173eb0372238339384102faa0",
        artifact_manifest_sha256: $kagent_evidence_sha,
        artifact_schema_version: "3",
        charts: {
          application: {ref: "oci://europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/helm/kagent@sha256:1111111111111111111111111111111111111111111111111111111111111111", version: "0.0.0-external-slot.kap.5"},
          crds: {ref: "oci://europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/helm/kagent-crds@sha256:2222222222222222222222222222222222222222222222222222222222222222", version: "0.0.0-external-slot.kap.5"}
        },
        image_refs: {
          controller: "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/controller@sha256:3333333333333333333333333333333333333333333333333333333333333333",
          ui: "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/ui@sha256:4444444444444444444444444444444444444444444444444444444444444444"
        },
        runtime_images: {
          kagentHarness: "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/golang-adk@sha256:5555555555555555555555555555555555555555555555555555555555555555",
          codexHarness: "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/codex-harness@sha256:6666666666666666666666666666666666666666666666666666666666666666"
        }
      },
      substrate: {
        source_repository: $evidence[0].source.repository,
        source_commit: $evidence[0].source.commit,
        artifact_manifest_sha256: $manifest_sha,
        artifact_schema_version: $evidence[0].schema_version,
        artifact_manifest_path: $manifest_path,
        charts: {
          application: {ref: $evidence[0].charts.application.ref, version: $evidence[0].charts.application.version},
          crds: {ref: $evidence[0].charts.crds.ref, version: $evidence[0].charts.crds.version}
        },
        image_refs: {
          ateapi: $evidence[0].images.ateapi.ref,
          atecontroller: $evidence[0].images.atecontroller.ref,
          atenet: $evidence[0].images.atenet.ref,
          agentgateway: $evidence[0].dependency_images.agentgateway.ref,
          releaseVerifier: $evidence[0].images.releaseVerifier.ref
        }
      }
    },
    compatibility: {
      kagent_rbac_create_false: true,
      kagent_obsolete_skills_init_removed: true,
      substrate_rbac_create_false: true,
      substrate_gateway_api_v1: true,
      substrate_go_module_commit: $evidence[0].source.commit
    },
    helm_set_values: {
      kagent: {
        "controller.image.registry": "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent",
        "controller.image.repository": "controller",
        "controller.image.tag": "0.0.0-external-slot.kap.5@sha256:3333333333333333333333333333333333333333333333333333333333333333",
        "ui.image.registry": "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent",
        "ui.image.repository": "ui",
        "ui.image.tag": "0.0.0-external-slot.kap.5@sha256:4444444444444444444444444444444444444444444444444444444444444444"
      },
      substrate: $evidence[0].helm_set_values
    },
    values_sha256: {
      "kagent/kagent.values.yaml": "1111111111111111111111111111111111111111111111111111111111111111",
      "kagent/kagent-dev.values.yaml": "2222222222222222222222222222222222222222222222222222222222222222",
      "kagent/kagent-prod.values.yaml": "3333333333333333333333333333333333333333333333333333333333333333",
      "kagent/substrate.values.yaml": "4444444444444444444444444444444444444444444444444444444444444444"
    },
    kagent_health_url: "http://kagent-controller.kagent-system.svc.cluster.local:8083/health",
    substrate_endpoint: "api.ate-system.svc.cluster.local:443",
    broker_server_name: "api.ate-system.svc",
    broker_service_name: "api",
    broker_service_port: 8443,
    atenet_egress_destinations: {}
  }' >"${valid_contract}"

kagent_fragment="${work}/kagent-fragment.hcl"
"${kagent_evidence_renderer}" \
  --evidence "${kagent_evidence}" \
  --evidence-uri "${kagent_evidence_uri}" \
  --evidence-sha256 "${kagent_evidence_sha}" \
  --gcloud "${fake_gcloud}" >"${kagent_fragment}" || \
  fail "checksum-bound kagent schema-3 evidence was rejected"
require_literal "${kagent_fragment}" "uri           = \"${kagent_evidence_uri}\""
require_literal "${kagent_fragment}" "artifact_manifest_sha256 = \"${kagent_evidence_sha}\""
require_literal "${kagent_fragment}" 'controller = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/controller@sha256:3333333333333333333333333333333333333333333333333333333333333333"'
require_literal "${kagent_fragment}" 'codexHarness  = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/codex-harness@sha256:6666666666666666666666666666666666666666666666666666666666666666"'
kagent_wrapper="${work}/kagent-fragment.tf"
{
  printf 'locals {\n'
  sed -e '/^#/d' -e '/^$/b' -e 's/^/  /' "${kagent_fragment}"
  printf '}\n'
} >"${kagent_wrapper}"
terraform fmt -check "${kagent_wrapper}" >/dev/null || fail "rendered kagent HCL fragment is not terraform-fmt clean"

if "${kagent_evidence_renderer}" \
  --evidence "${kagent_evidence}" \
  --evidence-uri "${kagent_evidence_uri}" \
  --evidence-sha256 "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
  --gcloud "${fake_gcloud}" \
  >"${work}/wrong-kagent-sha.out" 2>"${work}/wrong-kagent-sha.err"; then
  fail "renderer accepted kagent evidence with a mismatched authoritative checksum"
fi
[[ ! -s "${work}/wrong-kagent-sha.out" ]] || fail "failed kagent evidence rendering emitted a partial fragment"
require_literal "${work}/wrong-kagent-sha.err" 'evidence bytes do not match --evidence-sha256'

nonexistent_kagent_evidence_uri="gs://yourown-chat-kagent-preview-evidence-europe-west3/kagent/0.0.0-external-slot.kap.5/ffffffff-ffff-4fff-8fff-ffffffffffff/release-evidence.json#9999999999999999999"
if "${kagent_evidence_renderer}" \
  --evidence "${kagent_evidence}" \
  --evidence-uri "${nonexistent_kagent_evidence_uri}" \
  --evidence-sha256 "${kagent_evidence_sha}" \
  --gcloud "${fake_gcloud}" \
  >"${work}/missing-kagent-generation.out" 2>"${work}/missing-kagent-generation.err"; then
  fail "renderer accepted a nonexistent kagent evidence generation"
fi
[[ ! -s "${work}/missing-kagent-generation.out" ]] || \
  fail "missing kagent evidence generation emitted a partial fragment"
require_literal "${work}/missing-kagent-generation.err" \
  'gcloud storage cat could not read the exact evidence generation'

remote_kagent_evidence="${work}/remote-kagent-release-evidence.json"
printf '{}\n' >"${remote_kagent_evidence}"
if KAGENT_TEST_EVIDENCE_FILE="${remote_kagent_evidence}" \
  "${kagent_evidence_renderer}" \
  --evidence "${kagent_evidence}" \
  --evidence-uri "${kagent_evidence_uri}" \
  --evidence-sha256 "${kagent_evidence_sha}" \
  --gcloud "${fake_gcloud}" \
  >"${work}/mismatched-remote-evidence.out" 2>"${work}/mismatched-remote-evidence.err"; then
  fail "renderer accepted local evidence that differs from the exact remote generation"
fi
[[ ! -s "${work}/mismatched-remote-evidence.out" ]] || \
  fail "mismatched remote kagent evidence emitted a partial fragment"
require_literal "${work}/mismatched-remote-evidence.err" \
  'remote evidence generation bytes do not match local evidence'

valid_tfvars="${work}/valid-bootstrap.tfvars.json"
jq '{kagent_substrate_delivery: .}' "${valid_contract}" >"${valid_tfvars}"
terraform -chdir="${gate_module}" init -backend=false -input=false -no-color >/dev/null
terraform -chdir="${gate_module}" plan -refresh=false -input=false -lock=false -no-color \
  -var-file="${valid_tfvars}" >/dev/null || fail "canonical v0.0.22 bootstrap contract was rejected"

expect_bootstrap_failure() {
  local label="$1"
  local filter="$2"
  local tfvars="${work}/${label}.tfvars.json"
  local output="${work}/${label}.plan"
  jq "{kagent_substrate_delivery: (. ${filter})}" "${valid_contract}" >"${tfvars}"
  if terraform -chdir="${gate_module}" plan -refresh=false -input=false -lock=false -no-color \
    -var-file="${tfvars}" >"${output}" 2>&1; then
    fail "${label} bootstrap contract unexpectedly passed Stack validation"
  fi
  if ! grep -Fq -- 'Invalid value for variable' "${output}"; then
    sed -n '1,160p' "${output}" >&2
    fail "${label} did not fail through the canonical consumer evidence gate"
  fi
}

expect_bootstrap_failure changed-crd \
  '| .artifacts.substrate.charts.crds.ref = "oci://ghcr.io/pilprod/substrate/helm/substrate-crds@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-application \
  '| .artifacts.substrate.charts.application.ref = "oci://ghcr.io/pilprod/substrate/helm/substrate@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-image \
  '| .artifacts.substrate.image_refs.ateapi = "ghcr.io/pilprod/substrate/ateapi@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-helm-value \
  '| .helm_set_values.substrate["image.digests.ateapi"] = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-source \
  '| .artifacts.substrate.source_commit = "ffffffffffffffffffffffffffffffffffffffff" | .compatibility.substrate_go_module_commit = "ffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-evidence-hash \
  '| .artifacts.substrate.artifact_manifest_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-evidence-path \
  '| .artifacts.substrate.artifact_manifest_path = "kagent/evidence/substrate/v0.0.23/substrate-v0.0.23.consumer-evidence.json"'
expect_bootstrap_failure changed-evidence-schema \
  '| .artifacts.substrate.artifact_schema_version = "yourown.chat/substrate-semver-consumer-evidence/v2"'
expect_bootstrap_failure changed-kagent-source \
  '| .artifacts.kagent.source_commit = "ffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-kagent-application-version \
  '| .artifacts.kagent.charts.application.version = "0.0.0-external-slot.kap.6"'
expect_bootstrap_failure changed-kagent-crd-version \
  '| .artifacts.kagent.charts.crds.version = "0.0.0-external-slot.kap.6"'
expect_bootstrap_failure missing-kagent-evidence-binding \
  '| del(.kagent_release_evidence)'
expect_bootstrap_failure non-generation-qualified-kagent-evidence \
  '| .kagent_release_evidence.uri = "gs://yourown-chat-kagent-preview-evidence-europe-west3/kagent/0.0.0-external-slot.kap.5/release-evidence.json"'
expect_bootstrap_failure changed-kagent-evidence-checksum \
  '| .artifacts.kagent.artifact_manifest_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure changed-kagent-evidence-body \
  '| .kagent_release_evidence.manifest_json |= (fromjson | .channel = "production" | tojson + "\n")'
expect_bootstrap_failure same-registry-kagent-application-substitution \
  '| .artifacts.kagent.charts.application.ref = "oci://europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/helm/kagent@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure same-registry-kagent-crds-substitution \
  '| .artifacts.kagent.charts.crds.ref = "oci://europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/helm/kagent-crds@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure same-registry-kagent-controller-substitution \
  '| .artifacts.kagent.image_refs.controller = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/controller@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
   | .helm_set_values.kagent["controller.image.tag"] = "0.0.0-external-slot.kap.5@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure same-registry-kagent-ui-substitution \
  '| .artifacts.kagent.image_refs.ui = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/ui@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
   | .helm_set_values.kagent["ui.image.tag"] = "0.0.0-external-slot.kap.5@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure same-registry-kagent-harness-substitution \
  '| .artifacts.kagent.runtime_images.kagentHarness = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/golang-adk@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure same-registry-kagent-runtime-substitution \
  '| .artifacts.kagent.runtime_images.codexHarness = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent/codex-harness@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure helm-only-kagent-ui-substitution \
  '| .helm_set_values.kagent["ui.image.tag"] = "0.0.0-external-slot.kap.5@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_bootstrap_failure public-kagent-application-chart \
  '| .artifacts.kagent.charts.application.ref = "oci://ghcr.io/pilprod/kagent/helm/kagent@sha256:1111111111111111111111111111111111111111111111111111111111111111"'
expect_bootstrap_failure public-kagent-crd-chart \
  '| .artifacts.kagent.charts.crds.ref = "oci://ghcr.io/pilprod/kagent/helm/kagent-crds@sha256:2222222222222222222222222222222222222222222222222222222222222222"'
expect_bootstrap_failure public-kagent-controller \
  '| .artifacts.kagent.image_refs.controller = "ghcr.io/pilprod/kagent/controller@sha256:3333333333333333333333333333333333333333333333333333333333333333"'
expect_bootstrap_failure public-kagent-ui \
  '| .artifacts.kagent.image_refs.ui = "ghcr.io/pilprod/kagent/ui@sha256:4444444444444444444444444444444444444444444444444444444444444444"'
expect_bootstrap_failure public-kagent-harness \
  '| .artifacts.kagent.runtime_images.kagentHarness = "ghcr.io/pilprod/kagent/golang-adk@sha256:5555555555555555555555555555555555555555555555555555555555555555"'
expect_bootstrap_failure public-codex-harness \
  '| .artifacts.kagent.runtime_images.codexHarness = "ghcr.io/pilprod/kagent/codex-harness@sha256:6666666666666666666666666666666666666666666666666666666666666666"'

expect_kagent_manifest_failure() {
  local label="$1"
  local filter="$2"
  local candidate="${work}/${label}.json"
  local candidate_before_sha="${work}/${label}.before-sha.json"
  local manifest="${work}/${label}.manifest.json"
  local tfvars="${work}/${label}.tfvars.json"
  local output="${work}/${label}.plan"
  local manifest_sha

  jq "${filter}" "${valid_contract}" >"${candidate_before_sha}"
  jq -j '.kagent_release_evidence.manifest_json' "${candidate_before_sha}" >"${manifest}"
  manifest_sha="$(sha256_file "${manifest}")"
  jq --arg manifest_sha "${manifest_sha}" \
    '.artifacts.kagent.artifact_manifest_sha256 = $manifest_sha' \
    "${candidate_before_sha}" >"${candidate}"
  jq '{kagent_substrate_delivery: .}' "${candidate}" >"${tfvars}"

  if terraform -chdir="${gate_module}" plan -refresh=false -input=false -lock=false -no-color \
    -var-file="${tfvars}" >"${output}" 2>&1; then
    fail "${label} checksum-consistent malicious manifest unexpectedly passed Stack validation"
  fi
  if ! grep -Fq -- 'Invalid value for variable' "${output}"; then
    sed -n '1,160p' "${output}" >&2
    fail "${label} did not fail through the canonical consumer evidence gate"
  fi
}

# Recompute the exact evidence checksum after each mutation so these cases
# exercise the Stack scan-policy gate rather than failing only at byte binding.
expect_kagent_manifest_failure changed-kagent-scan-policy \
  '.kagent_release_evidence.manifest_json |= (
     fromjson
     | .security_scans.policy.id = "unreviewed-policy"
     | .security_scans.policy.evaluatorSha256 = ("9" * 64)
     | .security_scans.policy.blockedEffectiveSeverities = ["CRITICAL"]
     | tojson + "\n"
   )'
expect_kagent_manifest_failure changed-kagent-scan-decision \
  '.kagent_release_evidence.manifest_json |= (
     fromjson
     | .security_scans.targets["controller-linux-amd64"].highCriticalFindingCount = 1
     | .security_scans.targets["controller-linux-amd64"].blockingHighCriticalFindingCount = 1
     | tojson + "\n"
   )'
expect_kagent_manifest_failure changed-kagent-scan-platform-digest \
  '.kagent_release_evidence.manifest_json |= (
     fromjson
     | .security_scans.targets["controller-linux-amd64"].imageReference = "europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent/controller@sha256:9999999999999999999999999999999999999999999999999999999999999999"
     | tojson + "\n"
   )'

# Exercise the private producer-v2 branch through Terraform as well. The
# shared Substrate Helm release is applied before the Cloud Deploy renderer, so
# Terraform must bind every chart-consumed digest to the admitted image refs.
private_registry='europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate'
private_contract="${work}/valid-private-bootstrap-contract.json"
jq --arg registry "${private_registry}" \
  '.artifacts.substrate.artifact_schema_version = "yourown.chat/substrate-private-gar-release/v2"
   | .artifacts.substrate.artifact_manifest_sha256 = "b5aad6d44d359cd63fb2753c000579d948b1bb70c94bf0fbc3cdf21698c9789b"
   | .artifacts.substrate.artifact_manifest_path = ""
   | .artifacts.substrate.charts.application = {
       ref: ("oci://" + $registry + "/helm/substrate@sha256:51beebd226d0d2755b96dc70cf03072210222ab18f1f370b7b7c63fdd770a3af"),
       version: "0.0.22-private.3"
     }
   | .artifacts.substrate.charts.crds = {
       ref: ("oci://" + $registry + "/helm/substrate-crds@sha256:5333915d94c5a17c94e33533cc4698967a746b0ec686a8f19aef713ed5cab2c2"),
       version: "0.0.22-private.3"
     }
   | .artifacts.substrate.image_refs = {
       ateapi: ($registry + "/ateapi@sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868"),
       atecontroller: ($registry + "/atecontroller@sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554"),
       atenet: ($registry + "/atenet@sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c"),
       agentgateway: ($registry + "/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429"),
       releaseVerifier: ($registry + "/substrate-release-verify@sha256:850d8d8ec018f49486b410a15dd38e965f1fbb4d02f8a8be36d5256f33eef74b")
     }
   | .helm_set_values.substrate = {
       "image.registry": $registry,
       "image.digests.ateapi": "sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868",
       "image.digests.atecontroller": "sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554",
       "image.digests.atenet": "sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c",
       "images.agentgateway": ($registry + "/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429")
     }' "${valid_contract}" >"${private_contract}"

private_tfvars="${work}/valid-private-bootstrap.tfvars.json"
jq '{kagent_substrate_delivery: .}' "${private_contract}" >"${private_tfvars}"
terraform -chdir="${gate_module}" plan -refresh=false -input=false -lock=false -no-color \
  -var-file="${private_tfvars}" >/dev/null || fail "exact 0.0.22-private.3 bootstrap contract was rejected"

expect_private_failure() {
  local label="$1"
  local filter="$2"
  local tfvars="${work}/${label}.tfvars.json"
  local output="${work}/${label}.plan"
  jq "{kagent_substrate_delivery: (. ${filter})}" "${private_contract}" >"${tfvars}"
  if terraform -chdir="${gate_module}" plan -refresh=false -input=false -lock=false -no-color \
    -var-file="${tfvars}" >"${output}" 2>&1; then
    fail "${label} private bootstrap contract unexpectedly passed Stack validation"
  fi
  require_literal "${output}" 'Invalid value for variable'
}

expect_private_failure private-changed-evidence-hash \
  '| .artifacts.substrate.artifact_manifest_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_private_failure private-nonempty-evidence-path \
  '| .artifacts.substrate.artifact_manifest_path = "release-evidence.json"'
expect_private_failure private-changed-application-chart \
  '| .artifacts.substrate.charts.application.ref = "oci://europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/helm/substrate@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_private_failure private-changed-crd-chart \
  '| .artifacts.substrate.charts.crds.ref = "oci://europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/helm/substrate-crds@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'

for component in ateapi atecontroller atenet agentgateway; do
  expect_private_failure "private-changed-image-${component}" \
    "| .artifacts.substrate.image_refs.${component} = \"${private_registry}/${component}@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\""
done
expect_private_failure private-changed-image-releaseVerifier \
  "| .artifacts.substrate.image_refs.releaseVerifier = \"${private_registry}/substrate-release-verify@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\""

expect_private_failure private-changed-helm-registry \
  '| .helm_set_values.substrate["image.registry"] = "us-docker.pkg.dev/yourown-chat/kagent-preview/substrate"'
expect_private_failure private-changed-helm-ateapi \
  '| .helm_set_values.substrate["image.digests.ateapi"] = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_private_failure private-changed-helm-atecontroller \
  '| .helm_set_values.substrate["image.digests.atecontroller"] = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_private_failure private-changed-helm-atenet \
  '| .helm_set_values.substrate["image.digests.atenet"] = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_private_failure private-changed-helm-agentgateway \
  '| .helm_set_values.substrate["images.agentgateway"] = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/agentgateway@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_private_failure private-extra-image-key \
  '| .artifacts.substrate.image_refs.unreviewed = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/unreviewed@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_private_failure private-extra-helm-key \
  '| .helm_set_values.substrate.unreviewed = "true"'

printf 'Substrate semver consumer evidence tests passed\n'
