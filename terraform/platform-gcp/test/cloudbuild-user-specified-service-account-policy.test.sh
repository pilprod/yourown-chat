#!/usr/bin/env bash

set -euo pipefail

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
module="${platform_dir}/modules/cloudbuild-user-specified-service-account-policy/main.tf"
components="${platform_dir}/components.tfcomponent.hcl"

fail() {
  printf 'Cloud Build service-account policy test failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  grep -Fq -- "$2" "$1" || fail "$1 is missing: $2"
}

require_literal "${components}" '"orgpolicy.googleapis.com"'
require_literal "${components}" 'component "cloudbuild_user_specified_service_account_policy"'
require_literal "${components}" 'source = "./modules/cloudbuild-user-specified-service-account-policy"'
require_literal "${components}" 'project_id = component.project_services.project_id'
require_literal "${components}" 'depends_on = [component.project_services]'

require_literal "${module}" '"constraints/cloudbuild.useBuildServiceAccount"'
require_literal "${module}" '"constraints/cloudbuild.useComputeServiceAccount"'
require_literal "${module}" 'resource "google_org_policy_policy" "cloudbuild_user_specified_service_account"'
require_literal "${module}" 'for_each = local.cloudbuild_service_account_constraints'
require_literal "${module}" 'name   = "${local.project_parent}/policies/${trimprefix(each.value, "constraints/")}"'
require_literal "${module}" 'parent = local.project_parent'
require_literal "${module}" 'inherit_from_parent = false'
require_literal "${module}" 'enforce = "FALSE"'

if grep -Fq 'enforce = "TRUE"' "${module}"; then
  fail "Cloud Build default service-account constraints must not be enforced"
fi

constraint_count="$(grep -c '"constraints/cloudbuild\.use.*ServiceAccount"' "${module}")"
[[ "${constraint_count}" -eq 2 ]] || fail "expected exactly two Cloud Build service-account constraints"

printf 'Cloud Build user-specified service-account policy checks passed\n'
