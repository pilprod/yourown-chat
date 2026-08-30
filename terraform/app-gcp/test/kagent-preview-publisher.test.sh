#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
module_dir="${root_dir}/terraform/app-gcp/modules/kagent-preview-publisher"
components="${root_dir}/terraform/app-gcp/components.tfcomponent.hcl"
inputs="${root_dir}/terraform/app-gcp/service-inputs.tfdeploy.hcl"

fail() {
  printf 'kagent preview publisher contract failed: %s\n' "$1" >&2
  exit 1
}

for file in main.tf variables.tf outputs.tf; do
  test -f "${module_dir}/${file}" || fail "missing module file ${file}"
done

main="$(cat "${module_dir}/main.tf")"

for required in \
  'resource "google_service_account" "publisher"' \
  'roles/logging.logWriter' \
  'resource "google_storage_bucket" "evidence"' \
  'public_access_prevention    = "enforced"' \
  'force_destroy               = false' \
  'versioning {' \
  'retention_policy {' \
  'roles/storage.objectCreator' \
  'resource "google_secret_manager_secret" "ghcr_write"' \
  'roles/secretmanager.secretAccessor' \
  'resource "google_service_account_iam_member" "submitter"' \
  'roles/iam.serviceAccountUser'; do
  grep -Fq "${required}" <<<"${main}" || fail "missing least-privilege contract: ${required}"
done

if rg -n 'google_secret_manager_secret_version|secret_data|roles/storage\.objectAdmin|roles/secretmanager\.admin|roles/owner|roles/editor' "${module_dir}"; then
  fail 'module must not manage a token version or grant broad roles'
fi

grep -Fq 'source = "./modules/kagent-preview-publisher"' "${components}" ||
  fail 'stack component is not wired'
grep -Fq 'enabled                    = true' "${inputs}" ||
  fail 'service input does not materialize the publisher infrastructure'
grep -Fq 'submitter_members          = []' "${inputs}" ||
  fail 'unexpected persistent human submitter grant'

printf 'kagent preview publisher contracts passed\n'
