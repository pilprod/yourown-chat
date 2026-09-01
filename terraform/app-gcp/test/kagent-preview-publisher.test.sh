#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
module_dir="${root_dir}/terraform/app-gcp/modules/kagent-preview-publisher"
components="${root_dir}/terraform/app-gcp/components.tfcomponent.hcl"
inputs="${root_dir}/terraform/app-gcp/service-inputs.tfdeploy.hcl"
driver="${module_dir}/scripts/publish-artifact-registry.sh"
invoker="${module_dir}/scripts/publish-release-request.sh"

fail() {
  printf 'kagent preview publisher contract failed: %s\n' "$1" >&2
  exit 1
}

for file in main.tf variables.tf outputs.tf versions.tf scripts/evaluate-scan-vulnerabilities.sh scripts/publish-artifact-registry.sh scripts/publish-release-request.sh; do
  test -f "${module_dir}/${file}" || fail "missing module file ${file}"
done

grep -Fq 'gcloud pubsub topics publish' "${invoker}" ||
  fail 'release request must use the IAM-protected Pub/Sub topic'

main="$(cat "${module_dir}/main.tf")"
expected_substrate_evidence_case="'gs://\${var.evidence_bucket_name}/substrate/0.0.22-private.3/release-evidence.json#'[1-9][0-9]*) ;;"

grep -Fq '0\\.0\\.22-private\\.3/release-evidence\\.json#[1-9][0-9]*$' "${module_dir}/variables.tf" ||
  fail 'private Substrate evidence input must accept only the replacement coordinate'

for required in \
  'resource "google_service_account" "publisher"' \
  'roles/logging.logWriter' \
  'resource "google_cloudbuild_trigger" "release"' \
  'name            = "kagent-preview-release"' \
  'pubsub_config {' \
  '_RELEASE_TAG = "$(body.message.attributes.releaseTag)"' \
  'tag="$_RELEASE_TAG"' \
  "grep -Eq '\${var.release_tag_regex}'" \
  'test "$$(git cat-file -t "refs/tags/$$tag")" = tag' \
  'test "$$tag_commit" = "${var.source_commit}"' \
  'id         = "materialize-release-driver"' \
  'local.publication_driver_chunks' \
  'sha256sum --check --status' \
  'printf '\''%s'\'' "$$build_date" > /workspace/kagent-build-date' \
  'printf '\''%s'\'' "$$tag" > /workspace/kagent-source-tag' \
  'resource "google_artifact_registry_repository_iam_member" "release_writer"' \
  'resource "google_artifact_registry_repository_iam_member" "staging_writer"' \
  'roles/artifactregistry.writer' \
  'roles/ondemandscanning.admin' \
  'resource "google_project_iam_custom_role" "build_invoker"' \
  'permissions = ["cloudbuild.builds.create"]' \
  'resource "google_project_iam_custom_role" "apply_pubsub_manager"' \
  'role_id     = "kagentPreviewPubsubManager"' \
  '"pubsub.topics.create"' \
  '"pubsub.topics.delete"' \
  '"pubsub.topics.get"' \
  '"pubsub.topics.getIamPolicy"' \
  '"pubsub.topics.list"' \
  '"pubsub.topics.setIamPolicy"' \
  '"pubsub.topics.update"' \
  'resource "google_project_iam_member" "apply_pubsub_manager"' \
  'role    = google_project_iam_custom_role.apply_pubsub_manager[0].id' \
  'depends_on = [google_project_iam_member.apply_pubsub_manager]' \
  'resource "google_pubsub_topic_iam_member" "release_submitter"' \
  'roles/pubsub.publisher' \
  'resource "google_storage_bucket" "evidence"' \
  'public_access_prevention    = "enforced"' \
  'force_destroy               = false' \
  'versioning {' \
  'retention_policy {' \
  'roles/storage.objectCreator' \
  'resource "google_storage_bucket_iam_member" "evidence_viewer"' \
  'roles/storage.objectViewer' \
  'resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.evidence[0].name}/objects/substrate/0.0.22-private.3/\")' \
  'resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.evidence[0].name}/objects/kagent/\")' \
  'resource "google_secret_manager_secret" "ghcr_write"' \
  'resource "google_service_account_iam_member" "submitter"' \
  'for_each = var.enabled ? toset(["serviceAccount:${var.apply_service_account_email}"]) : toset([])' \
  'resource "google_service_account_iam_member" "publisher_acts_as_self"' \
  'roles/iam.serviceAccountUser'; do
  grep -Fq "${required}" <<<"${main}" || fail "missing least-privilege contract: ${required}"
done

for required in \
  'id         = "materialize-private-substrate-verification-inputs"' \
  "${expected_substrate_evidence_case}" \
  'gcloud storage cp "$$receipt_uri"' \
  'gcloud auth print-access-token' \
  'trap cleanup EXIT' \
  'rm -f \' \
  '--env SUBSTRATE_RELEASE_EVIDENCE=/workspace/private-substrate/release-evidence.json' \
  '--env SUBSTRATE_RELEASE_EVIDENCE_URI='\''${var.substrate_release_evidence_uri}'\''' \
  '--env HELM_REGISTRY_CONFIG=/workspace/private-substrate/registry-config.json'; do
  grep -Fq -- "${required}" <<<"${main}" ||
    fail "missing private Substrate verification input: ${required}"
done

grep -Eq '^[[:space:]]*service_account[[:space:]]*=[[:space:]]*google_service_account\.publisher\[0\]\.id[[:space:]]*$' <<<"${main}" ||
  fail 'Cloud Build trigger must explicitly execute as the publisher service account'
grep -Eq '^[[:space:]]*logging[[:space:]]*=[[:space:]]*"CLOUD_LOGGING_ONLY"[[:space:]]*$' <<<"${main}" ||
  fail 'custom Cloud Build service account must write logs directly to Cloud Logging'
if rg -n 'machine_type[[:space:]]*=[[:space:]]*"(E2|N1)_HIGHCPU_(8|32)"' "${module_dir}/main.tf"; then
  fail 'regional default-pool publisher must not require high-CPU quota'
fi

if rg -n 'google_cloudbuildv2_repository|repository_event_config|\$TAG_NAME|\$COMMIT_SHA' "${module_dir}"; then
  fail 'manual release rail must not depend on a Cloud Build GitHub connection or repository event'
fi

if rg -n 'roles/storage\.objectAdmin|roles/secretmanager\.admin|roles/cloudbuild\.builds\.builder|roles/owner|roles/editor' "${module_dir}"; then
  fail 'module must not grant broad roles'
fi
if rg -n '^[[:space:]]*role[[:space:]]*=[[:space:]]*"roles/pubsub\.(admin|editor)"' "${module_dir}"; then
  fail 'Terraform topic management must use the dedicated custom role'
fi
if rg -n 'random_password|release_webhook|secret_data' "${module_dir}"; then
  fail 'release request authorization must use Google IAM, not a shared secret in Terraform state'
fi
if rg -n 'available_secrets|availableSecrets|secret_env|secretEnv|ghcr\.io/pilprod/kagent|actions/' "${module_dir}"; then
  fail 'Artifact Registry trigger must not depend on GitHub Actions, GHCR or a package token'
fi

for required in \
  'components=(controller ui golang-adk codex-harness)' \
  'charts=(kagent kagent-crds)' \
  'staging_image_repository' \
  '--platform linux/amd64,linux/arm64' \
  '--provenance=mode=max' \
  '--sbom=true' \
  '--driver-opt "image=${buildkit_image}"' \
  'moby/buildkit@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8' \
  'assert_tag_absent' \
  'gcloud auth print-access-token' \
  'roles/ondemandscanning.admin' \
  'gcloud artifacts docker images scan' \
  'for architecture in amd64 arm64' \
  'evaluator=/workspace/evaluate-kagent-scan-vulnerabilities.sh' \
  'local.scan_policy_evaluator_chunks' \
  'local.scan_policy_evaluator_sha256' \
  'KAGENT_PUBLICATION_DRIVER_SHA256=${local.publication_driver_sha256}' \
  'KAGENT_SCAN_POLICY_EVALUATOR_SHA256=${local.scan_policy_evaluator_sha256}' \
  'KAGENT_TRUSTED_JQ_SHA256=${local.trusted_jq_sha256}' \
  'KAGENT_EXPECTED_BUILD_ID=$BUILD_ID' \
  'KAGENT_EXPECTED_PROJECT_ID=${var.project_id}' \
  'KAGENT_EXPECTED_SOURCE_COMMIT=${var.source_commit}' \
  'KAGENT_EXPECTED_SOURCE_TAG=$_RELEASE_TAG' \
  'platform_image_digests: $platform_digests' \
  'schema: "yourown.chat/kagent-platform-scan-evidence/v1"' \
  'blockedEffectiveSeverities: ["HIGH", "CRITICAL"]' \
  'gcloud storage cp "${lock_file}" "${lock_uri}" --if-generation-match=0' \
  'release.lock#${lock_generation}' \
  'schemaVersion: 3' \
  'release-evidence.json.sha256'; do
  grep -Fq -- "${required}" "${driver}" "${module_dir}/main.tf" ||
    fail "missing Artifact Registry publication contract: ${required}"
done
grep -Eq 'trusted_jq_index[[:space:]]*=[[:space:]]*"ghcr.io/jqlang/jq:1\.8\.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486"' "${module_dir}/main.tf" ||
  fail 'trusted JSON parser must retain the exact official jq multi-arch index provenance'
grep -Eq 'trusted_jq_amd64_image[[:space:]]*=[[:space:]]*"ghcr.io/jqlang/jq@sha256:1e7ad54d387c3ee4cb921f8a9de0d7f2359b375f04a37d10255fda4cd119029a"' "${module_dir}/main.tf" ||
  fail 'trusted JSON parser must pull the exact linux/amd64 child manifest'
grep -Eq 'trusted_jq_amd64_layer[[:space:]]*=[[:space:]]*"sha256:45f05cf73251ac39adec8657aba8dc90b26a9aa53ccb34323f2fb6929eb0fc74"' "${module_dir}/main.tf" ||
  fail 'trusted JSON parser must pin the exact linux/amd64 rootfs layer'
grep -Eq 'trusted_jq_sha256[[:space:]]*=[[:space:]]*"b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"' "${module_dir}/main.tf" ||
  fail 'trusted amd64 jq binary bytes must be pinned independently of the image index'
parser_block="$(sed -n '/id         = "materialize-pinned-json-parser"/,/^    }/p' "${module_dir}/main.tf")"
for required in \
  'gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311' \
  "docker pull --platform linux/amd64 '\${local.trusted_jq_amd64_image}'" \
  "docker create --platform linux/amd64 '\${local.trusted_jq_amd64_image}'" \
  'docker cp "$$container:/jq" "$$parser_stage/jq"' \
  "docker buildx imagetools inspect --raw '\${local.trusted_jq_index}'" \
  "docker buildx imagetools inspect --raw '\${local.trusted_jq_amd64_image}'" \
  '] == [$$child]' \
  'any(.layers[]; .digest == $$layer)' \
  "'\${local.trusted_jq_sha256}'" \
  'sha256sum --check --status'; do
  grep -Fq -- "${required}" <<<"${parser_block}" ||
    fail "missing pinned JSON parser materialization contract: ${required}"
done
if grep -Eq 'apt-get|apk add|dnf install|yum install|curl|wget' <<<"${parser_block}"; then
  fail 'trusted JSON parser must be extracted from pinned image bytes, not installed from a mutable package or URL'
fi
toolchain_block="$(sed -n '/id         = "verify-pinned-cloud-sdk-tool-contract"/,/^    }/p' "${module_dir}/main.tf")"
for required in \
  'gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3' \
  'parser=/workspace/trusted-bin/jq' \
  "'\${local.trusted_jq_sha256}'" \
  'sha256sum --check --status' \
  'test "$$($$parser --version)"' \
  "jq-1.8.2" \
  'test -x /usr/bin/python3' \
  'for tool in awk base64 chmod cmp cut grep mktemp mv sed sha256sum sort tr wc' \
  'test "$$(type -t mapfile)" = builtin' \
  'if command -v docker >/dev/null 2>&1'; do
  grep -Fq -- "${required}" <<<"${toolchain_block}" ||
    fail "missing early pinned Cloud SDK tool contract: ${required}"
done
grep -Fq 'trusted JSON parser integrity check failed' "${driver}" ||
  fail 'every trusted driver action must verify the pinned JSON parser bytes'
grep -Fq 'export KAGENT_JQ_PATH="${trusted_jq}"' "${driver}" ||
  fail 'driver must pass the explicit verified jq path to the scan policy evaluator'
grep -Fq 'trusted_jq="${KAGENT_JQ_PATH}"' "${module_dir}/scripts/evaluate-scan-vulnerabilities.sh" ||
  fail 'scan policy evaluator must use the explicit verified jq path'
grep -Fq '/usr/bin/python3 - "${vulnerabilities_json}"' "${module_dir}/scripts/evaluate-scan-vulnerabilities.sh" ||
  fail 'scan policy evaluator must use the exact Python path proven by the early Cloud SDK tool contract'
if rg -n '^[[:space:]]*jq[[:space:]]' "${driver}" "${module_dir}/scripts/evaluate-scan-vulnerabilities.sh"; then
  fail 'trusted driver and evaluator must not resolve jq from PATH'
fi
grep -Fq 'tag: ("v" + $version)' "${driver}" ||
  fail 'release evidence must retain the canonical artifact tag'
grep -Fq 'exec "$$driver" finalize-receipt' "${module_dir}/main.tf" ||
  fail 'receipt finalization must use the freshly rematerialized Terraform-pinned publication driver'
if grep -Fq 'finalize-cloud-build-fork-preview-receipt.py' "${module_dir}/main.tf"; then
  fail 'release finalization must not execute a mutable source-owned script'
fi

grep -Fq 'source = "./modules/kagent-preview-publisher"' "${components}" ||
  fail 'stack component is not wired'
grep -Fq 'github_remote_uri = var.source_repositories.kagent.remote_uri' "${components}" ||
  fail 'kagent source URI is not wired from the app-gcp catalog'
grep -Fq 'artifact_registry_repository_id = var.kagent_registry_repository_id' "${components}" ||
  fail 'platform-owned immutable kagent Artifact Registry repository is not wired'
grep -Fq 'artifact_registry_location      = var.kagent_registry_location' "${components}" ||
  fail 'dedicated kagent Artifact Registry location is not wired from platform-gcp'
grep -Fq 'staging_registry_repository_id  = var.kagent_staging_registry_repository_id' "${components}" ||
  fail 'platform-owned private kagent staging repository is not wired'
grep -Fq 'enabled                    = true' "${inputs}" ||
  fail 'service input does not materialize the publisher infrastructure'
grep -Fq 'source_commit              = "547cfe605940005173eb0372238339384102faa0"' "${inputs}" ||
  fail 'reviewed kagent source commit is not pinned'
grep -Fq 'substrate_release_evidence_uri = "gs://yourown-chat-kagent-preview-evidence-europe-west3/substrate/0.0.22-private.3/release-evidence.json#1788220783329855"' "${inputs}" ||
  fail 'generation-qualified private Substrate evidence is not pinned'
grep -Fq 'release_tag_regex          = "^gcp-v0\\.0\\.0-external-slot\\.kap\\.[0-9]+$"' "${inputs}" ||
  fail 'release tags must remain in the gcp-v namespace that cannot dispatch the fork v*.kap.* workflow'
grep -Fq 'submitter_members              = []' "${inputs}" ||
  fail 'unexpected persistent human submitter grant'
grep -Fq 'toset([var.workload_identity_members.mcp])' "${components}" ||
  fail 'Google Cloud MCP identity must be the default release-topic publisher'

scan_line="$(grep -n 'id         = "scan-candidate-images"' "${module_dir}/main.tf" | cut -d: -f1)"
pre_scan_verify_line="$(grep -n 'id         = "reverify-platform-bindings-before-scan"' "${module_dir}/main.tf" | cut -d: -f1)"
parser_line="$(grep -n 'id         = "materialize-pinned-json-parser"' "${module_dir}/main.tf" | cut -d: -f1)"
toolchain_line="$(grep -n 'id         = "verify-pinned-cloud-sdk-tool-contract"' "${module_dir}/main.tf" | cut -d: -f1)"
candidate_build_line="$(grep -n 'id         = "build-candidate-images"' "${module_dir}/main.tf" | cut -d: -f1)"
package_line="$(grep -n 'id         = "package-and-reproduce-charts"' "${module_dir}/main.tf" | cut -d: -f1)"
record_line="$(grep -n 'id         = "record-buildkit-image-digests"' "${module_dir}/main.tf" | cut -d: -f1)"
lock_line="$(grep -n 'id         = "acquire-immutable-release-lock"' "${module_dir}/main.tf" | cut -d: -f1)"
promote_line="$(grep -n 'id         = "promote-final-image-aliases"' "${module_dir}/main.tf" | cut -d: -f1)"
assemble_line="$(grep -n 'id         = "assemble-deployment-evidence"' "${module_dir}/main.tf" | cut -d: -f1)"
post_assemble_verify_line="$(grep -n 'id         = "reverify-platform-bindings-after-assembly"' "${module_dir}/main.tf" | cut -d: -f1)"
[[ "${package_line}" -lt "${record_line}" ]] ||
  fail 'all source-owned chart packaging must finish before trusted image digest recording'
[[ "${parser_line}" -lt "${toolchain_line}" && "${toolchain_line}" -lt "${candidate_build_line}" ]] ||
  fail 'exact parser and Cloud SDK tool closure must fail before the expensive candidate build'
[[ "${pre_scan_verify_line}" -lt "${scan_line}" ]] ||
  fail 'pinned Docker-builder platform binding must run before the Cloud SDK scan'
previous_step_id="$(sed -n "1,$((scan_line - 1))p" "${module_dir}/main.tf" |
  grep -E '^[[:space:]]+id[[:space:]]+=' | tail -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
[[ "${previous_step_id}" == "reverify-platform-bindings-before-scan" ]] ||
  fail 'pinned Docker-builder platform binding must be immediately before the Cloud SDK scan'
[[ "${scan_line}" -lt "${lock_line}" && "${lock_line}" -lt "${promote_line}" ]] ||
  fail 'candidate scan and release lock must complete before any final image is promoted'
[[ "${assemble_line}" -lt "${post_assemble_verify_line}" ]] ||
  fail 'registry platform bindings must be re-derived after the writable evidence assembly boundary'
grep -Fq 'docker buildx imagetools create --tag "${final}" "${staging_repository}@${expected}"' "${driver}" ||
  fail 'final images must be promoted from the private scanned staging digest'
publish_charts_block="$(sed -n '/id         = "publish-final-charts"/,/^    }/p' "${module_dir}/main.tf")"
grep -Fq -- '--network cloudbuild' <<<"${publish_charts_block}" ||
  fail 'nested chart publication container must reach Cloud Build ADC over the cloudbuild network'
grep -Fq 'docker buildx imagetools inspect --raw "${candidate_digest}"' "${driver}" ||
  fail 'platform child digests must be extracted from the exact candidate index digest, never a mutable staging tag'
scan_action="$(sed -n '/^  scan-images)/,/^    ;;/p' "${driver}")"
promotion_action="$(sed -n '/^  promote-images)/,/^    ;;/p' "${driver}")"
if grep -Eq '^[[:space:]]*docker[[:space:]]|verify_remote_platform_binding|inspect_digest' <<<"${scan_action}"; then
  fail 'Cloud SDK scan action must not require Docker or repeat registry index inspection'
fi
grep -Fq 'reference="$(staging_image_repository "${component}")@${digest}"' <<<"${scan_action}" ||
  fail 'scan must address each child by immutable staging digest only'
if grep -Fq 'candidate_tag' <<<"${scan_action}"; then
  fail 'scan action must not use a mutable staging tag'
fi
grep -Fq 'verify_remote_platform_binding "${component}"' <<<"${promotion_action}" ||
  fail 'promotion must re-derive and compare the index platform children from the exact registry digest'
grep -Fq '.annotations["vnd.docker.reference.type"] == "attestation-manifest"' "${driver}" ||
  fail 'candidate index validation must reject unscanned runnable platforms while allowing BuildKit attestations'
if grep -Fq 'shift' <<<"$(sed -n '/id         = "materialize-release-driver"/,/^    }/p' "${module_dir}/main.tf")"; then
  fail 'driver materialization must preserve every base64 chunk passed after bash argv[0]'
fi
scan_block="$(sed -n '/id         = "scan-candidate-images"/,/^    }/p' "${module_dir}/main.tf")"
pre_scan_verify_block="$(sed -n '/id         = "reverify-platform-bindings-before-scan"/,/^    }/p' "${module_dir}/main.tf")"
grep -Fq 'gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311' <<<"${pre_scan_verify_block}" ||
  fail 'pre-scan platform binding must run in the pinned Docker builder'
grep -Fq 'local.publication_driver_chunks' <<<"${pre_scan_verify_block}" ||
  fail 'pre-scan platform binding must reconstruct the Terraform-pinned driver'
grep -Fq "printf '%s  %s\\n' '\${local.publication_driver_sha256}'" <<<"${pre_scan_verify_block}" ||
  fail 'pre-scan platform binding must verify the Terraform-pinned driver hash'
grep -Fq 'exec "$$driver" verify-platform-bindings' <<<"${pre_scan_verify_block}" ||
  fail 'pre-scan Docker builder must re-read exact index platform children'
if grep -Fq 'kagent-fork-preview-tools' <<<"${pre_scan_verify_block}"; then
  fail 'source-built toolbox must not be trusted for final pre-scan platform binding'
fi
if grep -Eq '^[[:space:]]*docker[[:space:]]|cloud-builders/docker|kagent-fork-preview-tools' <<<"${scan_block}"; then
  fail 'pinned Cloud SDK scan step must not require Docker or a source-built toolbox'
fi

for source_step in \
  verify-release-source \
  package-and-reproduce-charts \
  record-buildkit-image-digests \
  record-candidate-platform-digests \
  publish-final-charts \
  assemble-deployment-evidence; do
  source_block="$(sed -n "/id         = \"${source_step}\"/,/^    }/p" "${module_dir}/main.tf")"
  grep -Fq -- '--volume /workspace/trusted-bin:/workspace/trusted-bin:ro' <<<"${source_block}" ||
    fail "source-built toolbox step ${source_step} must receive the trusted parser read-only"
done
for source_driver_step in \
  record-buildkit-image-digests \
  record-candidate-platform-digests \
  publish-final-charts \
  assemble-deployment-evidence; do
  source_driver_block="$(sed -n "/id         = \"${source_driver_step}\"/,/^    }/p" "${module_dir}/main.tf")"
  grep -Fq -- '--env KAGENT_TRUSTED_JQ_SHA256' <<<"${source_driver_block}" ||
    fail "nested trusted driver step ${source_driver_step} must receive the parser SHA pin"
done
grep -Fq 'driver_chunks=("$$${@:1:driver_chunk_count}")' <<<"${scan_block}" ||
  fail 'scan step must reconstruct the trusted driver from its Terraform chunks'
grep -Fq 'local.publication_driver_chunks' <<<"${scan_block}" ||
  fail 'scan step must receive the pinned driver chunks'
grep -Fq 'local.scan_policy_evaluator_chunks' <<<"${scan_block}" ||
  fail 'scan step must receive the pinned evaluator chunks'
[[ "$(grep -Fc 'sha256sum --check --status' <<<"${scan_block}")" -eq 2 ]] ||
  fail 'scan step must verify both reconstructed script hashes immediately before execution'
grep -Fq 'exec "$$driver" scan-images' <<<"${scan_block}" ||
  fail 'scan step must execute the freshly verified driver directly'
grep -Fq 'publication driver integrity check failed' "${driver}" ||
  fail 'every driver action must verify the Terraform-pinned driver hash'
grep -Fq 'scan policy evaluator integrity check failed' "${driver}" ||
  fail 'image scanning must verify the Terraform-pinned evaluator hash'
grep -Fq '.policy.evaluatorSha256 == $evaluator_sha256' "${driver}" ||
  fail 'policy evidence must bind the exact evaluator hash'
grep -Fq '.rawVulnerabilitiesSha256 == $input_sha256' "${driver}" ||
  fail 'policy evidence must bind the exact raw vulnerability result'
grep -Fq 'verify_final_registry_digests' "${driver}" ||
  fail 'trusted finalization must re-read every final image and chart tag from Artifact Registry'
grep -Fq 'gcloud storage cat "${lock_base_uri}#${generation}"' "${driver}" ||
  fail 'trusted finalization must re-read the generation-qualified immutable release lock'
grep -Fq 'cmp -s "${remote_lock}" "${release_dir}/release-lock.json"' "${driver}" ||
  fail 'uploaded release-lock evidence must match the exact immutable remote bytes'
grep -Fq 'platform_digests="$(platform_digests_json)" || return 1' "${driver}" ||
  fail 'release evidence must reconstruct platform digests from the eight registry-verified child files'
grep -Fq "'. == \$expected' \"\${release_inputs}/platform-image-digests.json\"" "${driver}" ||
  fail 'mutable aggregate platform digest evidence must equal the reconstructed child digest map'
[[ "$(grep -Fc 'gcloud artifacts docker images list-vulnerabilities' "${driver}")" -eq 1 ]] ||
  fail 'scan evidence and severity summary must derive from one immutable scanner response'

assemble_block="$(sed -n '/id         = "assemble-deployment-evidence"/,/^    }/p' "${module_dir}/main.tf")"
grep -Fq -- '--network cloudbuild' <<<"${assemble_block}" ||
  fail 'nested evidence assembly must reach Cloud Build ADC over the cloudbuild network'
grep -Fq -- '--env KAGENT_EVIDENCE_BUCKET' <<<"${assemble_block}" ||
  fail 'evidence assembly must receive the immutable lock bucket'
post_assemble_verify_block="$(sed -n '/id         = "reverify-platform-bindings-after-assembly"/,/^    }/p' "${module_dir}/main.tf")"
grep -Fq 'local.publication_driver_chunks' <<<"${post_assemble_verify_block}" ||
  fail 'post-assembly registry verification must rematerialize the Terraform-pinned driver'
grep -Fq 'exec "$$driver" verify-platform-bindings' <<<"${post_assemble_verify_block}" ||
  fail 'post-assembly registry verification must re-read exact index platform children'

upload_block="$(sed -n '/id         = "upload-immutable-release-receipt"/,/^    }/p' "${module_dir}/main.tf")"
finalizer_block="$(sed -n '/id         = "finalize-cloud-build-receipt"/,/^    }/p' "${module_dir}/main.tf")"
for trusted_block in "${finalizer_block}" "${upload_block}"; do
  grep -Fq 'local.publication_driver_chunks' <<<"${trusted_block}" ||
    fail 'finalization and upload must each receive the Terraform-pinned driver chunks'
  grep -Fq "printf '%s' \"\$\$@\" | base64 -d" <<<"${trusted_block}" ||
    fail 'finalization and upload must each rematerialize the pinned driver immediately before use'
  grep -Fq "'\${local.publication_driver_sha256}'" <<<"${trusted_block}" ||
    fail 'finalization and upload must each verify the Terraform-pinned driver digest'
done
grep -Fq 'jq_path=/workspace/trusted-bin/jq' <<<"${upload_block}" ||
  fail 'receipt uploader must use the explicit pinned JSON parser path'
grep -Fq "'\${local.trusted_jq_sha256}' \"\$\$jq_path\"" <<<"${upload_block}" ||
  fail 'receipt uploader must verify the parser SHA immediately before inline JSON generation'
grep -Fq '"$$jq_path" -n' <<<"${upload_block}" ||
  fail 'receipt uploader must not resolve jq from the Cloud SDK image PATH'
if grep -Eq '(^|[^$])\$\$\{' "${module_dir}/main.tf"; then
  fail 'Terraform must render braced shell expansions as Cloud Build $$ escapes, never single-dollar substitutions'
fi
if grep -Eq '(^|[^$])\$[a-z]' "${module_dir}/main.tf"; then
  fail 'inline shell and jq variables must be escaped from Cloud Build substitution'
fi
grep -Fq -- '--if-generation-match=0' <<<"${upload_block}" ||
  fail 'every final receipt object must be uploaded create-only'
grep -Fq 'release-receipt.json' <<<"${upload_block}" ||
  fail 'final upload must root the evidence and checksum manifest in a release receipt'
grep -Fq 'trusted_anchors="$$("$$driver" prepare-upload)"' <<<"${upload_block}" ||
  fail 'uploader must revalidate the trusted precomputed release-evidence hash and structure'
for required in \
  'set -o pipefail' \
  'trusted_anchors="$$("$$driver" prepare-upload)"' \
  'anchor_sha() {' \
  '[[ "$$(sha256sum "$$name" | cut -d'\'' '\'' -f1)" == "$$anchored_sha" ]]' \
  'gcloud storage cat "$$destination#$$generation"' \
  '[[ "$$remote_sha" == "$$anchored_sha" ]]'; do
  grep -Fq -- "${required}" <<<"${upload_block}" ||
    fail "upload must bind local and generation-read-back bytes to the prevalidated digest: ${required}"
done
upload_array="$(sed -n '/upload=(/,/^          )/p' <<<"${upload_block}")"
last_upload="$(awk '
  /upload=\(/ { inside = 1; next }
  inside && /^          \)/ { exit }
  inside && NF && $1 !~ /^#/ { last = $1 }
  END { print last }
' <<<"${upload_array}")"
[[ "${last_upload}" == "release-receipt.json" ]] ||
  fail 'release receipt must be uploaded last as the immutable commit marker'
grep -Fq 'schema: "yourown.chat/kagent-private-gar-receipt/v1"' <<<"${upload_block}" ||
  fail 'final release receipt must carry the private GAR schema identity'
grep -Fq 'evidence_uri=%s/release-evidence.json#%s' <<<"${upload_block}" ||
  fail 'publisher must emit a generation-qualified evidence coordinate'
if grep -Fq 'gcloud storage cp ./*' <<<"${upload_block}"; then
  fail 'final receipt upload must use an exact validated whitelist, never a workspace glob'
fi
grep -Fq 'local name="${evidence_prefix}-${suffix}"' "${driver}" ||
  fail 'receipt must checksum scan evidence for both amd64 and arm64 child manifests'
grep -Fq '"${release_dir}/${evidence_prefix}-scan-policy.json"' "${driver}" ||
  fail 'scan policy decision must be retained in the immutable release receipt'
grep -Fq 'for suffix in scan-id.txt vulnerabilities.json severities.txt scan-policy.json' "${driver}" ||
  fail 'scan policy decision must be checksummed with the raw vulnerability result'

printf 'kagent preview publisher contracts passed\n'
