#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source_manifest="${repo_root}/helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json"
source_checksum="${source_manifest}.sha256"
source_module="${repo_root}/helm/kagent/substrate_consumer_evidence.py"
source_renderer="${repo_root}/terraform/app-gcp/scripts/render-substrate-semver-consumer-pin-fragment.py"

fail() {
  printf 'Substrate semver consumer evidence test failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local path="$1"
  local literal="$2"
  grep -Fq -- "${literal}" "${path}" || fail "${path} is missing: ${literal}"
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

printf 'Substrate semver consumer evidence tests passed\n'
