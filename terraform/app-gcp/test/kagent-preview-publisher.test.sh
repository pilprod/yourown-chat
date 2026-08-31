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

for file in main.tf variables.tf outputs.tf versions.tf scripts/publish-artifact-registry.sh scripts/publish-release-request.sh; do
  test -f "${module_dir}/${file}" || fail "missing module file ${file}"
done

grep -Fq 'gcloud pubsub topics publish' "${invoker}" ||
  fail 'release request must use the IAM-protected Pub/Sub topic'

main="$(cat "${module_dir}/main.tf")"

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
  'resource "google_pubsub_topic_iam_member" "release_submitter"' \
  'roles/pubsub.publisher' \
  'resource "google_storage_bucket" "evidence"' \
  'public_access_prevention    = "enforced"' \
  'force_destroy               = false' \
  'versioning {' \
  'retention_policy {' \
  'roles/storage.objectCreator' \
  'resource "google_secret_manager_secret" "ghcr_write"' \
  'resource "google_service_account_iam_member" "apply_acts_as_publisher"' \
  'resource "google_service_account_iam_member" "publisher_acts_as_self"' \
  'roles/iam.serviceAccountUser'; do
  grep -Fq "${required}" <<<"${main}" || fail "missing least-privilege contract: ${required}"
done

if rg -n 'google_cloudbuildv2_repository|repository_event_config|\$TAG_NAME|\$COMMIT_SHA' "${module_dir}"; then
  fail 'manual release rail must not depend on a Cloud Build GitHub connection or repository event'
fi

if rg -n 'roles/storage\.objectAdmin|roles/secretmanager\.admin|roles/cloudbuild\.builds\.builder|roles/owner|roles/editor' "${module_dir}"; then
  fail 'module must not grant broad roles'
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
  'platform_image_digests: $platform_digests' \
  'gcloud storage cp - "${lock_uri}" --if-generation-match=0' \
  'schemaVersion: 3' \
  'release-evidence.json.sha256'; do
  grep -Fq -- "${required}" "${driver}" "${module_dir}/main.tf" ||
    fail "missing Artifact Registry publication contract: ${required}"
done
grep -Fq 'tag: $source_tag' "${driver}" ||
  fail 'receipt must record the exact reviewed gcp-v source tag'

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
grep -Fq 'source_commit              = "a23b96ec863315ea3ca0ccd2ea829197882bd509"' "${inputs}" ||
  fail 'reviewed kagent source commit is not pinned'
grep -Fq 'release_tag_regex          = "^gcp-v0\\.0\\.0-external-slot\\.kap\\.[0-9]+$"' "${inputs}" ||
  fail 'release tags must remain in the gcp-v namespace that cannot dispatch the fork v*.kap.* workflow'
grep -Fq 'submitter_members          = []' "${inputs}" ||
  fail 'unexpected persistent human submitter grant'
grep -Fq 'toset([var.workload_identity_members.mcp])' "${components}" ||
  fail 'Google Cloud MCP identity must be the default release-topic publisher'

scan_line="$(grep -n 'id         = "scan-candidate-images"' "${module_dir}/main.tf" | cut -d: -f1)"
lock_line="$(grep -n 'id         = "acquire-immutable-release-lock"' "${module_dir}/main.tf" | cut -d: -f1)"
promote_line="$(grep -n 'id         = "promote-final-image-aliases"' "${module_dir}/main.tf" | cut -d: -f1)"
[[ "${scan_line}" -lt "${lock_line}" && "${lock_line}" -lt "${promote_line}" ]] ||
  fail 'candidate scan and release lock must complete before any final image is promoted'
grep -Fq 'docker buildx imagetools create --tag "${final}" "${staging_repository}@${expected}"' "${driver}" ||
  fail 'final images must be promoted from the private scanned staging digest'
publish_charts_block="$(sed -n '/id         = "publish-final-charts"/,/^    }/p' "${module_dir}/main.tf")"
grep -Fq -- '--network cloudbuild' <<<"${publish_charts_block}" ||
  fail 'nested chart publication container must reach Cloud Build ADC over the cloudbuild network'
grep -Fq 'docker buildx imagetools inspect --raw "${candidate_digest}"' "${driver}" ||
  fail 'platform child digests must be extracted from the exact candidate index digest, never a mutable staging tag'
grep -Fq '.annotations["vnd.docker.reference.type"] == "attestation-manifest"' "${driver}" ||
  fail 'candidate index validation must reject unscanned runnable platforms while allowing BuildKit attestations'
if grep -Fq 'shift' <<<"$(sed -n '/id         = "materialize-release-driver"/,/^    }/p' "${module_dir}/main.tf")"; then
  fail 'driver materialization must preserve every base64 chunk passed after bash argv[0]'
fi
grep -Fq 'name="${component}-linux-${architecture}-${suffix}"' "${driver}" ||
  fail 'receipt must checksum scan evidence for both amd64 and arm64 child manifests'

printf 'kagent preview publisher contracts passed\n'
