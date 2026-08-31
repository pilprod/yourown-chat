#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
module_dir="${root_dir}/terraform/app-gcp/modules/substrate-preview-publisher"
components="${root_dir}/terraform/app-gcp/components.tfcomponent.hcl"
inputs="${root_dir}/terraform/app-gcp/service-inputs.tfdeploy.hcl"
app="${root_dir}/terraform/app-gcp/app.tfdeploy.hcl"
outputs="${root_dir}/terraform/app-gcp/outputs.tfcomponent.hcl"
driver="${module_dir}/scripts/publish-private-gar.sh"
invoker="${module_dir}/scripts/publish-release-request.sh"

fail() {
  printf 'Substrate private publisher contract failed: %s\n' "$1" >&2
  exit 1
}

for file in main.tf variables.tf outputs.tf versions.tf scripts/publish-private-gar.sh scripts/publish-release-request.sh; do
  test -f "${module_dir}/${file}" || fail "missing module file ${file}"
done

bash -n "${driver}"
bash -n "${invoker}"

main="$(cat "${module_dir}/main.tf")"

for required in \
  'resource "google_service_account" "publisher"' \
  'account_id   = "substrate-publisher"' \
  'roles/logging.logWriter' \
  'resource "google_artifact_registry_repository_iam_member" "release_writer"' \
  'resource "google_artifact_registry_repository_iam_member" "staging_writer"' \
  'roles/artifactregistry.writer' \
  'roles/ondemandscanning.admin' \
  'resource "google_storage_bucket_iam_member" "evidence_creator"' \
  'roles/storage.objectCreator' \
  'resource "google_storage_bucket_iam_member" "evidence_viewer"' \
  'roles/storage.objectViewer' \
  'resource.name.startsWith(\"projects/_/buckets/${var.evidence_bucket_name}/objects/substrate/${var.release_version}/\")' \
  'resource "google_pubsub_topic" "release_request"' \
  'name    = "substrate-private-release"' \
  'resource "google_pubsub_topic_iam_member" "release_submitter"' \
  'roles/pubsub.publisher' \
  'resource "google_cloudbuild_trigger" "release"' \
  '_RELEASE_VERSION = "$(body.message.attributes.releaseVersion)"' \
  'filter = "_RELEASE_VERSION == \"${var.release_version}\""' \
  'test "$$release_version" = '\''${var.release_version}'\''' \
  'test "$$(git cat-file -t "refs/tags/${var.source_tag}")" = tag' \
  'tag_commit="$$(git rev-parse "refs/tags/${var.source_tag}^{}")"' \
  'test "$$tag_object" = "${var.source_tag_object}"' \
  'test "$$tag_commit" = "${var.source_commit}"' \
  'logging = "CLOUD_LOGGING_ONLY"'; do
  grep -Fq "${required}" <<<"${main}" || fail "missing private release contract: ${required}"
done

[[ "$(grep -Fc 'resource.name.startsWith(\"projects/_/buckets/${var.evidence_bucket_name}/objects/substrate/${var.release_version}/\")' "${module_dir}/main.tf")" -eq 2 ]] ||
  fail 'creator and viewer grants must both be restricted to the exact Substrate release prefix'
grep -Fq 'google_service_account_iam_member.apply_acts_as_publisher,' "${module_dir}/main.tf" ||
  fail 'trigger must wait for the apply identity actAs grant'

if rg -n 'resource "google_storage_bucket"|allUsers|allAuthenticatedUsers|roles/(owner|editor)|roles/storage\.objectAdmin|roles/artifactregistry\.admin|roles/pubsub\.(admin|editor)' "${module_dir}"; then
  fail 'module must reuse the retained evidence bucket and must not grant broad or public roles'
fi

if rg -n 'available_secrets|secret_env|secretEnv|github_token|ghcr_write|docker\.pkg\.dev/.+/:latest' "${module_dir}"; then
  fail 'private publisher must not depend on package credentials or mutable final tags'
fi

grep -Fq 'condition     = var.release_version == "0.0.22-private.1"' "${module_dir}/variables.tf" ||
  fail 'module must authorize exactly one applied private release coordinate'
grep -Fq 'condition     = var.source_tag == "v0.0.22"' "${module_dir}/variables.tf" ||
  fail 'reviewed annotated source tag is not fixed'
grep -Fq 'condition     = var.source_tag_object == "00a6a684cea3b3feea67461cf79347332ec759ef"' "${module_dir}/variables.tf" ||
  fail 'reviewed annotated tag object is not fixed'
grep -Fq 'condition     = var.source_commit == "e9ed68e587b56df2aa2a7f0267a744598c4d48b4"' "${module_dir}/variables.tf" ||
  fail 'reviewed peeled source commit is not fixed'
grep -Fq 'readonly expected_release_version="0.0.22-private.1"' "${invoker}" ||
  fail 'manual submitter must reject any coordinate not authorized by the applied configuration'
grep -Fq 'gcloud pubsub topics publish substrate-private-release' "${invoker}" ||
  fail 'manual request must use the IAM-protected Google Pub/Sub topic'

for required in \
  'readonly expected_release_prefix="europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate"' \
  'readonly expected_staging_prefix="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/substrate"' \
  '[[ "${source_tag}" == "v0.0.22" ]]' \
  '[[ "${source_commit}" == "e9ed68e587b56df2aa2a7f0267a744598c4d48b4" ]]' \
  'docker buildx imagetools create --tag "${candidate}" "${source_ref}"' \
  'gcloud artifacts docker images scan' \
  'for architecture in amd64 arm64' \
  '> "${release_inputs}/platform-image-digests.json"' \
  'printf '\''%s\n'\'' "${reference}" > "${release_dir}/${evidence_prefix}-scan-target.txt"' \
  'gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9)' \
  'info.uid = 0' \
  'info.gid = 0' \
  'info.mode = 0o755' \
  'info.mode = 0o644' \
  'for destination in first second' \
  'cmp "${chart_dist}/first/${archive}" "${chart_dist}/second/${archive}"' \
  'gcloud storage cp - "${lock_uri}" --if-generation-match=0' \
  'docker buildx imagetools create --tag "${final}" "${staging_repository}@${expected}"' \
  'registry_visibility: "private"' \
  'schema_version: "yourown.chat/substrate-private-gar-release/v1"' \
  'source_image_refs: $source_image_refs' \
  'platform_image_digests: $platform_digests' \
  'package_sha256: $application_package_sha' \
  'package_sha256: $crds_package_sha' \
  '[[ "${application_package_sha}" =~ ^sha256:[0-9a-f]{64}$ ]]' \
  '[[ "${crds_package_sha}" =~ ^sha256:[0-9a-f]{64}$ ]]' \
  'printf '\''evidence_uri=%s#%s\n'\''' \
  'printf '\''evidence_sha256=%s\n'\''' \
  'gcloud storage cp "${path}" "${destination}/${name}" --if-generation-match=0'; do
  grep -Fq -- "${required}" "${driver}" || fail "missing fail-closed driver contract: ${required}"
done

[[ "$(grep -Fc 'package_sha256: $application_package_sha' "${driver}")" -eq 2 ]] ||
  fail 'application archive SHA must be retained in both release evidence and receipt'
[[ "$(grep -Fc 'package_sha256: $crds_package_sha' "${driver}")" -eq 2 ]] ||
  fail 'CRD archive SHA must be retained in both release evidence and receipt'

scan_line="$(grep -n 'id         = "scan-staged-images"' "${module_dir}/main.tf" | cut -d: -f1)"
lock_line="$(grep -n 'id         = "acquire-immutable-release-lock"' "${module_dir}/main.tf" | cut -d: -f1)"
promote_line="$(grep -n 'id         = "promote-private-image-indexes"' "${module_dir}/main.tf" | cut -d: -f1)"
charts_line="$(grep -n 'id         = "publish-private-charts"' "${module_dir}/main.tf" | cut -d: -f1)"
receipt_line="$(grep -n 'id         = "upload-retained-private-receipt"' "${module_dir}/main.tf" | cut -d: -f1)"
[[ "${scan_line}" -lt "${lock_line}" && "${lock_line}" -lt "${promote_line}" && \
   "${promote_line}" -lt "${charts_line}" && "${charts_line}" -lt "${receipt_line}" ]] ||
  fail 'scan, write-once lock, promotion, chart publication and receipt upload ordering changed'

grep -Fq 'source = "./modules/substrate-preview-publisher"' "${components}" ||
  fail 'stack component is not wired'
grep -Fq 'github_remote_uri = var.source_repositories.substrate.remote_uri' "${components}" ||
  fail 'reviewed Substrate source is not catalog-wired'
grep -Fq 'artifact_registry_repository_id = var.kagent_registry_repository_id' "${components}" ||
  fail 'private immutable platform repository is not wired'
grep -Fq 'staging_registry_repository_id  = var.kagent_staging_registry_repository_id' "${components}" ||
  fail 'private disposable platform repository is not wired'
grep -Fq 'component.kagent_preview_publisher.evidence_bucket_name' "${components}" ||
  fail 'retained evidence bucket must be referenced through its owning component output'
grep -Fq 'evidence_bucket_owner_enabled = var.kagent_preview_publisher.enabled' "${components}" ||
  fail 'enabled Substrate publisher must receive the evidence-bucket owner gate'
grep -Fq 'condition     = var.evidence_bucket_owner_enabled' "${module_dir}/main.tf" ||
  fail 'module must fail closed when the evidence-bucket owner is disabled'
grep -Fq 'substrate_preview_publisher = local.substrate_preview_publisher' "${app}" ||
  fail 'deployment input is not wired'
grep -Fq 'output "substrate_preview_publisher"' "${outputs}" ||
  fail 'non-sensitive publisher coordinates are not exported'

for required in \
  'remote_uri = "https://github.com/pilprod/substrate.git"' \
  'enabled           = true' \
  'source_tag        = "v0.0.22"' \
  'source_tag_object = "00a6a684cea3b3feea67461cf79347332ec759ef"' \
  'source_commit     = "e9ed68e587b56df2aa2a7f0267a744598c4d48b4"' \
  'release_version   = "0.0.22-private.1"' \
  'submitter_members = []'; do
  grep -Fq "${required}" "${inputs}" || fail "applied private release input is missing: ${required}"
done

if "${invoker}" 0.0.22-private.2 >/dev/null 2>&1; then
  fail 'manual submitter accepted a coordinate not authorized by the applied configuration'
fi

printf 'Substrate private publisher contracts passed\n'
