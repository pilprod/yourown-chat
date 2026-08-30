#!/usr/bin/env bash
set -euo pipefail

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
module="${platform_dir}/modules/cloudsql/main.tf"
module_variables="${platform_dir}/modules/cloudsql/variables.tf"
components="${platform_dir}/components.tfcomponent.hcl"
variables="${platform_dir}/variables.tfcomponent.hcl"
services="${platform_dir}/service-inputs.tfdeploy.hcl"

fail() { printf 'Cloud SQL database adoption test failed: %s\n' "$*" >&2; exit 1; }
require_literal() { grep -Fq -- "$2" "$1" || fail "$1 is missing: $2"; }
require_pattern() { grep -Eq -- "$2" "$1" || fail "$1 is missing pattern: $2"; }

require_literal "${module}" 'if database.adopt_existing'
require_literal "${module}" 'to = google_sql_database.additional[each.key]'
# The interpolation is intentionally asserted as literal Terraform source.
# shellcheck disable=SC2016
require_literal "${module}" 'id = "projects/${var.project_id}/instances/${local.instance_name}/databases/${each.value.database_name}"'
require_pattern "${module_variables}" 'adopt_existing_database_names[[:space:]]*=[[:space:]]*optional\(set\(string\), \[\]\)'
require_literal "${module_variables}" 'length(setsubtract(settings.adopt_existing_database_names, settings.database_names)) == 0'
require_literal "${module_variables}" '(settings.manage_databases || length(settings.adopt_existing_database_names) == 0)'
require_literal "${module_variables}" 'Set adopt_existing_database_names only for a reviewed one-shot import, then clear it after success; the imported resources remain managed in state.'
require_pattern "${variables}" 'adopt_existing_database_names[[:space:]]*=[[:space:]]*optional\(set\(string\), \[\]\)'
require_literal "${variables}" 'Set adopt_existing_database_names only for a reviewed one-shot import, then clear it after success; the imported resources remain managed in state.'
require_literal "${components}" 'adopt_existing_database_names = settings.adopt_existing_database_names'

kagent_block="$(awk '
  /^    kagent = \{/ { capture = 1 }
  capture { print }
  capture && /^    \}$/ { exit }
' "${services}")"
substrate_block="$(awk '
  /^    substrate = \{/ { capture = 1 }
  capture { print }
  capture && /^    \}$/ { exit }
' "${services}")"

[[ -n "${kagent_block}" ]] || fail "kagent service block was not found"
[[ -n "${substrate_block}" ]] || fail "substrate service block was not found"
[[ "${kagent_block}" != *'adopt_existing_database_names'* ]] \
  || fail "kagent must remain on the normal database create path"
[[ "${substrate_block}" != *'adopt_existing_database_names'* ]] \
  || fail "substrate adoption must be disabled after the successful import"
if grep -Eq '^[[:space:]]+adopt_existing_database_names[[:space:]]*=' "${services}"; then
  fail "no service may retain a completed one-shot database adoption opt-in"
fi

printf 'Cloud SQL database adoption tests passed\n'
