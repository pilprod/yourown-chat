#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
generator="${app_dir}/scripts/render-substrate-preview-pin-fragment.sh"

fail() {
  printf 'substrate preview pin fragment test failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local input_file="$1"
  local literal="$2"

  grep -Fq -- "${literal}" "${input_file}" || fail "${input_file} is missing: ${literal}"
}

sha256_file() {
  local input_file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${input_file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${input_file}" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

repeat_hex() {
  local character="$1"
  local count="$2"

  printf "%${count}s" '' | tr ' ' "${character}"
}

temporary_dir="$(mktemp -d)"
if [[ -n "${KEEP_SUBSTRATE_PIN_TEST_TMP:-}" ]]; then
  printf 'substrate preview pin fragment test fixtures: %s\n' "${temporary_dir}" >&2
else
  trap 'rm -rf "${temporary_dir}"' EXIT
fi
fixture_repo="${temporary_dir}/repository"
fixture_app="${fixture_repo}/terraform/app-gcp"
fixture_values="${fixture_repo}/helm/vendor/substrate"
artifact_dir="${temporary_dir}/artifact"
mkdir -p "${fixture_app}/scripts" "${fixture_values}" "${artifact_dir}"
cp "${generator}" "${fixture_app}/scripts/"
chmod +x "${fixture_app}/scripts/$(basename "${generator}")"
git -C "${fixture_repo}" init -q
fixture_generator="${fixture_app}/scripts/$(basename "${generator}")"

sha="$(repeat_hex 1 40)"
digest_a="sha256:$(repeat_hex a 64)"
digest_b="sha256:$(repeat_hex b 64)"
digest_c="sha256:$(repeat_hex c 64)"
digest_d="sha256:$(repeat_hex d 64)"
digest_e="sha256:$(repeat_hex e 64)"
digest_f="sha256:$(repeat_hex f 64)"
digest_g="sha256:$(repeat_hex 0 64)"
digest_h="sha256:$(repeat_hex 7 64)"
manifest="${artifact_dir}/substrate-gke-preview.json"
crds_values="${fixture_values}/crds.values.yaml"
application_values="${fixture_values}/application.values.yaml"

printf '{}\n' > "${crds_values}"
printf '%s\n' \
  'profile: external-control-plane-only' \
  'image:' \
  '  registry: ghcr.io/kagent-dev/substrate' \
  '  tag: ""' \
  '  digests:' \
  "    ateapi: ${digest_a}" \
  "    atecontroller: ${digest_b}" \
  "    atenet: ${digest_f}" \
  'images:' \
  "  agentgateway: ghcr.io/kagent-dev/substrate/agentgateway@${digest_g}" > "${application_values}"

write_manifest() {
  jq -n --sort-keys \
    --arg sha "${sha}" \
    --arg digest_a "${digest_a}" \
    --arg digest_b "${digest_b}" \
    --arg digest_c "${digest_c}" \
    --arg digest_d "${digest_d}" \
    --arg digest_e "${digest_e}" \
    --arg digest_f "${digest_f}" \
    --arg digest_g "${digest_g}" \
    --arg digest_h "${digest_h}" \
    '{
      schema_version: "yourown.chat/substrate-gke-preview/v1",
      deployment_class: "testbed",
      production_eligible: false,
      source: {
        repository: "kagent-dev/substrate",
        commit: $sha
      },
      candidate: {
        image_tag: ("sha-" + $sha),
        chart_version: "0.42.1",
        image_registry: "ghcr.io/kagent-dev/substrate"
      },
      image_digests: {
        ateapi: $digest_a,
        atecontroller: $digest_b,
        "ateom-gvisor": $digest_c,
        atenet: $digest_f,
        releaseVerifier: $digest_h
      },
      helm_values: {
        image: {
          registry: "ghcr.io/kagent-dev/substrate",
          digests: {
            ateapi: $digest_a,
            atecontroller: $digest_b,
            atenet: $digest_f
          }
        },
        images: {
          agentgateway: ("ghcr.io/kagent-dev/substrate/agentgateway@" + $digest_g)
        }
      },
      images: {
        ateapi: {ref: ("ghcr.io/kagent-dev/substrate/ateapi@" + $digest_a)},
        atecontroller: {ref: ("ghcr.io/kagent-dev/substrate/atecontroller@" + $digest_b)},
        "ateom-gvisor": {ref: ("ghcr.io/kagent-dev/substrate/ateom-gvisor@" + $digest_c)},
        atenet: {ref: ("ghcr.io/kagent-dev/substrate/atenet@" + $digest_f)},
        agentgateway: {ref: ("ghcr.io/kagent-dev/substrate/agentgateway@" + $digest_g)},
        releaseVerifier: {ref: ("ghcr.io/kagent-dev/substrate/substrate-release-verify@" + $digest_h)}
      },
      charts: {
        crds: {
          release_name: "substrate-crds",
          ref: ("oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds@" + $digest_d),
          version: "0.42.1",
          digest: $digest_d
        },
        application: {
          release_name: "substrate",
          ref: ("oci://ghcr.io/kagent-dev/substrate/helm/substrate@" + $digest_e),
          version: "0.42.1",
          digest: $digest_e
        }
      }
    }' > "${manifest}"
  printf '%s  substrate-gke-preview.json\n' "$(sha256_file "${manifest}")" > "${manifest}.sha256"
}

refresh_checksum() {
  printf '%s  substrate-gke-preview.json\n' "$(sha256_file "${manifest}")" > "${manifest}.sha256"
}

mutate_manifest() {
  local filter="$1"
  local replacement="${artifact_dir}/replacement.json"

  jq "${filter}" "${manifest}" > "${replacement}"
  mv "${replacement}" "${manifest}"
  refresh_checksum
}

expect_failure() {
  local label="$1"
  local expected_error="$2"
  local stdout_file="${temporary_dir}/${label}.stdout"
  local stderr_file="${temporary_dir}/${label}.stderr"

  if "${fixture_generator}" "${manifest}" "${crds_values}" "${application_values}" \
    > "${stdout_file}" 2> "${stderr_file}"; then
    fail "${label} unexpectedly succeeded"
  fi
  [[ ! -s "${stdout_file}" ]] || fail "${label} emitted a partial fragment"
  require_literal "${stderr_file}" "${expected_error}"
}

write_manifest
output="${temporary_dir}/fragment.hcl"
errors="${temporary_dir}/fragment.stderr"
if ! "${fixture_generator}" "${manifest}" "${crds_values}" "${application_values}" \
  > "${output}" 2> "${errors}"; then
  sed 's/^/generator: /' "${errors}" >&2
  fail "valid producer handoff was rejected"
fi

require_literal "${output}" '# INCOMPLETE immutable-pin fragment; this is not a vendor_chart_bundles entry.'
require_literal "${output}" "# manifest_sha256: $(sha256_file "${manifest}")"
require_literal "${output}" '# source_repository: kagent-dev/substrate'
require_literal "${output}" "# preview_image_tag: sha-${sha}"
require_literal "${output}" "# external_worker_image_ref: ghcr.io/kagent-dev/substrate/ateom-gvisor@${digest_c}"
require_literal "${output}" "# agentgateway_image_ref: ghcr.io/kagent-dev/substrate/agentgateway@${digest_g}"
require_literal "${output}" "# release_verifier_image_ref: ghcr.io/kagent-dev/substrate/substrate-release-verify@${digest_h}"
require_literal "${output}" "source_commit       = \"${sha}\""
require_literal "${output}" "ateapi          = \"${digest_a}\""
require_literal "${output}" "atecontroller   = \"${digest_b}\""
require_literal "${output}" "atenet          = \"${digest_f}\""
require_literal "${output}" "agentgateway    = \"${digest_g}\""
require_literal "${output}" "releaseVerifier = \"${digest_h}\""
require_literal "${output}" 'values_path   = "helm/vendor/substrate/crds.values.yaml"'
require_literal "${output}" "values_sha256 = \"$(sha256_file "${crds_values}")\""
require_literal "${output}" 'values_path   = "helm/vendor/substrate/application.values.yaml"'
require_literal "${output}" "values_sha256 = \"$(sha256_file "${application_values}")\""
require_literal "${errors}" 'a full bundle still requires reviewed fields:'
require_literal "${errors}" 'provisioned, application_enabled, candidate_tag, product_commit,'
if grep -Eq '^[[:space:]]*(provisioned|application_enabled|candidate_tag|product_commit|namespaces|endpoints|flows|database_bindings)[[:space:]]*=' "${output}"; then
  fail "the pin fragment synthesized a full-bundle field"
fi
if grep -Fq -- '"ateom-gvisor" =' "${output}"; then
  fail "the external WorkerPool image was misrepresented as a chart-consumed digest"
fi

wrapper="${temporary_dir}/wrapper.tf"
{
  printf 'locals {\n  substrate_preview_pins = {\n'
  sed -e '/^$/b' -e 's/^/    /' "${output}"
  printf '  }\n}\n'
} > "${wrapper}"
terraform fmt -check "${wrapper}" >/dev/null || fail "generated fragment is not terraform-fmt clean"

write_manifest
mutate_manifest '.source.repository = "pilprod/substrate" | .candidate.image_registry = "ghcr.io/pilprod/substrate"'
expect_failure pilprod-source 'manifest violates the closed Substrate preview v1 contract'

printf 'bad checksum\n' > "${manifest}.sha256"
expect_failure checksum 'manifest does not match its producer checksum'

write_manifest
mutate_manifest '.unexpected = true'
expect_failure unknown-key 'manifest violates the closed Substrate preview v1 contract'

write_manifest
duplicate_manifest="${artifact_dir}/duplicate.json"
sed '1a\
  "schema_version": "yourown.chat/substrate-gke-preview/v1",' "${manifest}" > "${duplicate_manifest}"
mv "${duplicate_manifest}" "${manifest}"
refresh_checksum
expect_failure duplicate-json 'manifest must contain one JSON value with unique object keys'

write_manifest
mutate_manifest '.source.repository = "fork/substrate" | .candidate.image_registry = "ghcr.io/fork/substrate"'
expect_failure source 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest 'del(.image_digests.atenet, .helm_values.image.digests.atenet, .images.atenet)'
expect_failure missing-atenet 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest '.helm_values.image.digests.atenet = .image_digests.ateapi'
expect_failure mismatched-atenet 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest 'del(.helm_values.images.agentgateway, .images.agentgateway)'
expect_failure missing-agentgateway 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest '.helm_values.images.agentgateway = "ghcr.io/kagent-dev/substrate/agentgateway@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_failure mismatched-agentgateway 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest 'del(.images.releaseVerifier)'
expect_failure missing-release-verifier 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest '.images.releaseVerifier.ref = "ghcr.io/kagent-dev/substrate/not-the-release-verifier@sha256:7777777777777777777777777777777777777777777777777777777777777777"'
expect_failure mismatched-release-verifier 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest 'del(.image_digests.releaseVerifier)'
expect_failure missing-release-verifier-digest 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest '.image_digests.releaseVerifier = .image_digests.ateapi'
expect_failure mismatched-release-verifier-digest 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest '.candidate.image_tag = "latest"'
expect_failure image-tag 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest '.images.ateapi.ref = "ghcr.io/kagent-dev/substrate/ateapi@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
expect_failure image-ref 'manifest violates the closed Substrate preview v1 contract'

write_manifest
mutate_manifest '.charts.application.version = "0.42.2"'
expect_failure chart-version 'manifest violates the closed Substrate preview v1 contract'

write_manifest
printf '%s\n' \
  'image:' \
  '  registry: ghcr.io/kagent-dev/substrate' \
  '  digests:' \
  "    ateapi: ${digest_a}" \
  "    atecontroller: ${digest_c}" \
  "    atenet: ${digest_f}" \
  'images:' \
  "  agentgateway: ghcr.io/kagent-dev/substrate/agentgateway@${digest_g}" > "${application_values}"
expect_failure values-digest 'application values image pins must exactly match manifest.helm_values.image'

printf '%s\n' \
  'image:' \
  '  registry: ghcr.io/kagent-dev/substrate' \
  '  registry: ghcr.io/kagent-dev/substrate' \
  '  digests:' \
  "    ateapi: ${digest_a}" \
  "    atecontroller: ${digest_b}" \
  "    atenet: ${digest_f}" \
  'images:' \
  "  agentgateway: ghcr.io/kagent-dev/substrate/agentgateway@${digest_g}" > "${application_values}"
expect_failure duplicate-yaml 'application values image pins must exactly match manifest.helm_values.image'

printf '%s\n' \
  'image:' \
  '  registry: ghcr.io/kagent-dev/substrate' \
  '  digests:' \
  "    ateapi: ${digest_a}" \
  "    atecontroller: ${digest_b}" \
  "    atenet: ${digest_f}" \
  'images:' \
  "  agentgateway: ghcr.io/kagent-dev/substrate/agentgateway@${digest_g}" > "${application_values}"
outside_values="${temporary_dir}/application.values.yaml"
cp "${application_values}" "${outside_values}"
if "${fixture_generator}" "${manifest}" "${crds_values}" "${outside_values}" >/dev/null 2>&1; then
  fail "generator accepted values outside the repository-owned Substrate directory"
fi

printf 'substrate preview pin fragment tests passed\n'
