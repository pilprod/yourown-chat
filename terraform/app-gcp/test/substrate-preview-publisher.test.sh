#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
module_dir="${root_dir}/terraform/app-gcp/modules/substrate-preview-publisher"
components="${root_dir}/terraform/app-gcp/components.tfcomponent.hcl"
inputs="${root_dir}/terraform/app-gcp/service-inputs.tfdeploy.hcl"
stack_variables="${root_dir}/terraform/app-gcp/variables.tfcomponent.hcl"
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
expected_evidence_viewer_expression='expression  = "(resource.type == \"storage.googleapis.com/Bucket\" && resource.name == \"projects/_/buckets/${var.evidence_bucket_name}\") || (resource.type == \"storage.googleapis.com/Object\" && resource.name.startsWith(\"projects/_/buckets/${var.evidence_bucket_name}/objects/substrate/${var.release_version}/\"))"'

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
  "${expected_evidence_viewer_expression}" \
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

test "$(grep -Fc "${expected_evidence_viewer_expression}" <<<"${main}")" -eq 1 ||
  fail "private evidence viewer condition must have one exact bucket-list and release-prefix-read expression"

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

grep -Fq 'condition     = var.release_version == "0.0.22-private.2"' "${module_dir}/variables.tf" ||
  fail 'module must authorize exactly one applied private release coordinate'
grep -Fq 'var.substrate_preview_publisher.release_version == "0.0.22-private.2"' "${stack_variables}" ||
  fail 'Stack input must authorize exactly the replacement private release coordinate'
grep -Fq 'condition     = var.source_tag == "v0.0.22"' "${module_dir}/variables.tf" ||
  fail 'reviewed annotated source tag is not fixed'
grep -Fq 'condition     = var.source_tag_object == "00a6a684cea3b3feea67461cf79347332ec759ef"' "${module_dir}/variables.tf" ||
  fail 'reviewed annotated tag object is not fixed'
grep -Fq 'condition     = var.source_commit == "e9ed68e587b56df2aa2a7f0267a744598c4d48b4"' "${module_dir}/variables.tf" ||
  fail 'reviewed peeled source commit is not fixed'
grep -Fq 'readonly expected_release_version="0.0.22-private.2"' "${invoker}" ||
  fail 'manual submitter must reject any coordinate not authorized by the applied configuration'
grep -Fq 'gcloud pubsub topics publish substrate-private-release' "${invoker}" ||
  fail 'manual request must use the IAM-protected Google Pub/Sub topic'

expected_component_block=$'readonly required_components=(\n  agentgateway\n  ateapi\n  atecontroller\n  atenet\n)'
actual_component_block="$(sed -n '/^readonly required_components=(/,/^)/p' "${driver}")"
[[ "${actual_component_block}" == "${expected_component_block}" ]] ||
  fail 'private release component scope must remain exactly agentgateway, ateapi, atecontroller and atenet'
grep -Fq 'readonly all_components=("${required_components[@]}")' "${driver}" ||
  fail 'all staging, scan and promotion loops must derive from the closed required component set'

for excluded in atelet ateom-gvisor ateom-microvm podcertcontroller substrate-release-verify; do
  if grep -Fq -- "${excluded}" "${driver}"; then
    fail "profile-excluded component leaked into private release driver: ${excluded}"
  fi
done

for required in \
  'readonly expected_release_prefix="europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate"' \
  'readonly expected_staging_prefix="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/substrate"' \
  '[[ "${release_version}" == "0.0.22-private.2" ]]' \
  '[[ "${source_tag}" == "v0.0.22" ]]' \
  '[[ "${source_commit}" == "e9ed68e587b56df2aa2a7f0267a744598c4d48b4" ]]' \
  'docker buildx imagetools create --tag "${candidate}" "${source_ref}"' \
  'gcloud artifacts docker images scan' \
  'for architecture in amd64 arm64' \
  'if grep -Exq '\''CRITICAL|HIGH'\'' "${release_dir}/${evidence_prefix}-severities.txt"; then' \
  '> "${release_inputs}/platform-image-digests.json"' \
  'printf '\''%s\n'\'' "${reference}" > "${release_dir}/${evidence_prefix}-scan-target.txt"' \
  'gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9)' \
  'output="$("${HELM_BIN}" push "${archive}" "oci://${SUBSTRATE_RELEASE_PREFIX}/helm" 2>&1)"' \
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
  'supported_profiles: ["external-control-plane-only"]' \
  'required_components: ["agentgateway", "ateapi", "atecontroller", "atenet"]' \
  '$evidence.copy_provenance.source_image_refs == {' \
  '($evidence.images | keys) == ["agentgateway", "ateapi", "atecontroller", "atenet"]' \
  '($evidence.platform_image_digests | keys) == ["agentgateway", "ateapi", "atecontroller", "atenet"]' \
  'all($evidence.required_components[];' \
  '. as $component |' \
  '$evidence.images[$component].digest ==' \
  'capture("@(?<digest>sha256:[0-9a-f]{64})$").digest)' \
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

guard_filter="$({
  sed -n '/# RELEASE_EVIDENCE_GUARD_BEGIN/,/# RELEASE_EVIDENCE_GUARD_END/p' "${driver}" |
    sed '1,/--arg release_prefix/d; /^    '\'' "${release_dir}\/release-evidence.json"/,$d' |
    sed 's/^      //'
})"
[[ -n "${guard_filter}" ]] || fail 'could not extract the runtime evidence guard'

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
release_prefix='europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate'
valid_evidence="${test_dir}/valid-evidence.json"
cat > "${valid_evidence}" <<'JSON'
{
  "supported_profiles": ["external-control-plane-only"],
  "required_components": ["agentgateway", "ateapi", "atecontroller", "atenet"],
  "copy_provenance": {
    "source_image_refs": {
      "agentgateway": "ghcr.io/kagent-dev/substrate/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429",
      "ateapi": "ghcr.io/pilprod/substrate/ateapi@sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868",
      "atecontroller": "ghcr.io/pilprod/substrate/atecontroller@sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554",
      "atenet": "ghcr.io/pilprod/substrate/atenet@sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c"
    }
  },
  "images": {
    "agentgateway": {"digest": "sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429", "ref": "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429"},
    "ateapi": {"digest": "sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868", "ref": "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/ateapi@sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868"},
    "atecontroller": {"digest": "sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554", "ref": "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/atecontroller@sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554"},
    "atenet": {"digest": "sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c", "ref": "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/atenet@sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c"}
  },
  "platform_image_digests": {
    "agentgateway": {"linux_amd64": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linux_arm64": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    "ateapi": {"linux_amd64": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linux_arm64": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    "atecontroller": {"linux_amd64": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linux_arm64": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    "atenet": {"linux_amd64": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "linux_arm64": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  }
}
JSON

jq -e --arg release_prefix "${release_prefix}" "${guard_filter}" "${valid_evidence}" >/dev/null ||
  fail 'runtime evidence guard rejected the exact reviewed evidence contract'

digest_mismatch="${test_dir}/digest-mismatch.json"
jq '.images.ateapi.digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" |
    .images.ateapi.ref = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/ateapi@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "${valid_evidence}" > "${digest_mismatch}"
if jq -e --arg release_prefix "${release_prefix}" "${guard_filter}" "${digest_mismatch}" >/dev/null; then
  fail 'runtime evidence guard accepted an image digest that differs from its pinned source ref'
fi

source_ref_mismatch="${test_dir}/source-ref-mismatch.json"
jq '.copy_provenance.source_image_refs.ateapi = "ghcr.io/pilprod/substrate/ateapi@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" |
    .images.ateapi.digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" |
    .images.ateapi.ref = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate/ateapi@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "${valid_evidence}" > "${source_ref_mismatch}"
if jq -e --arg release_prefix "${release_prefix}" "${guard_filter}" "${source_ref_mismatch}" >/dev/null; then
  fail 'runtime evidence guard accepted a source ref outside the four reviewed GHCR pins'
fi

for source_ref in \
  'ghcr.io/kagent-dev/substrate/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429' \
  'ghcr.io/pilprod/substrate/ateapi@sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868' \
  'ghcr.io/pilprod/substrate/atecontroller@sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554' \
  'ghcr.io/pilprod/substrate/atenet@sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c'; do
  [[ "$(grep -Fc -- "${source_ref}" "${driver}")" -eq 2 ]] ||
    fail "pinned source ref must appear once in the copier and once in the runtime evidence guard: ${source_ref}"
done

images_block="$(sed -n '/^        images: {/,/^        },/p' "${driver}")"
for component in agentgateway ateapi atecontroller atenet; do
  grep -Eq "^[[:space:]]+${component}: \\{ref:" <<<"${images_block}" ||
    fail "release evidence images is missing required component ${component}"
done
[[ "$(grep -Ec '^[[:space:]]+[a-z][a-z0-9-]*: \{ref:' <<<"${images_block}")" -eq 4 ]] ||
  fail 'release evidence images must contain exactly the four required profile components'

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
  'release_version   = "0.0.22-private.2"' \
  'submitter_members = []'; do
  grep -Fq "${required}" "${inputs}" || fail "applied private release input is missing: ${required}"
done

if "${invoker}" 0.0.22-private.1 >/dev/null 2>&1; then
  fail 'manual submitter accepted a coordinate not authorized by the applied configuration'
fi

printf 'Substrate private publisher contracts passed\n'
