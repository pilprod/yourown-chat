#!/usr/bin/env bash

set -euo pipefail

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
components="${platform_dir}/components.tfcomponent.hcl"
variables="${platform_dir}/variables.tfcomponent.hcl"
outputs="${platform_dir}/outputs.tfcomponent.hcl"
deployment="${platform_dir}/platform.tfdeploy.hcl"

grep -Fq 'component "artifact_registry_kagent"' "${components}" || {
  echo "missing platform-owned kagent Artifact Registry component" >&2
  exit 1
}
grep -Fq 'component "artifact_registry_kagent_staging"' "${components}" || {
  echo "missing private kagent candidate staging repository" >&2
  exit 1
}
release_block="$(sed -n '/component "artifact_registry_kagent" {/,/^}/p' "${components}")"
grep -Fq 'immutable_tags         = true' <<<"${release_block}" || {
  echo "kagent Artifact Registry tags must be immutable" >&2
  exit 1
}
grep -Fq 'keep_untagged_days     = 0' <<<"${release_block}" || {
  echo "immutable kagent release artifacts must not have an expiry cleanup policy" >&2
  exit 1
}
grep -Fq 'keep_recent_versions   = 0' <<<"${release_block}" || {
  echo "immutable kagent release versions must not be count-pruned" >&2
  exit 1
}
if grep -Fq 'allUsers' <<<"${release_block}"; then
  echo "kagent Artifact Registry must remain private under Domain Restricted Sharing; public distribution is deferred" >&2
  exit 1
fi
grep -Fq 'current distribution contract is private Artifact Registry only' "${components}" || {
  echo "kagent distribution contract must document private Artifact Registry as the only current target" >&2
  exit 1
}
if grep -Eq 'distribution is promoted separately to GHCR|before public immutable promotion' "${components}" "${variables}"; then
  echo "kagent registry contract must not claim that public GHCR promotion currently exists" >&2
  exit 1
fi
grep -Fq 'delete_tagged_days     = 1' "${components}" || {
  echo "private kagent candidate tags need bounded cleanup" >&2
  exit 1
}
grep -Fq 'vulnerability_scanning = false' "${components}" || {
  echo "routine repository scanning must remain disabled; app-gcp scans release candidates on demand" >&2
  exit 1
}
grep -Fq 'variable "kagent_registry_repository_id"' "${variables}" || {
  echo "missing kagent registry input" >&2
  exit 1
}
grep -Fq 'output "kagent_registry_repository_path"' "${outputs}" || {
  echo "missing kagent registry component output" >&2
  exit 1
}
grep -Fq 'publish_output "kagent_registry_repository_id"' "${deployment}" || {
  echo "missing linked-stack kagent registry output" >&2
  exit 1
}
grep -Fq 'publish_output "kagent_staging_registry_repository_id"' "${deployment}" || {
  echo "missing linked-stack private kagent staging registry output" >&2
  exit 1
}

echo "kagent immutable preview registry contract checks passed"
