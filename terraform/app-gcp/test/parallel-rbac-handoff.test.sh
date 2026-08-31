#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
main="${app_dir}/modules/substrate-prerequisites/main.tf"
module_outputs="${app_dir}/modules/substrate-prerequisites/outputs.tf"
stack_outputs="${app_dir}/outputs.tfcomponent.hcl"
release_doc="${app_dir}/../../docs/KAGENT_SUBSTRATE_RELEASE.md"
chart_readme="${app_dir}/../../helm/kagent/README.md"

fail() {
  printf 'parallel RBAC handoff test failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  rg -Fq -- "${literal}" "${file}" || fail "${file} is missing: ${literal}"
}

require_regex() {
  local file="$1"
  local pattern="$2"
  rg -q -- "${pattern}" "${file}" || fail "${file} does not match: ${pattern}"
}

forbid_literal() {
  local file="$1"
  local literal="$2"
  if rg -Fq -- "${literal}" "${file}"; then
    fail "${file} still contains forbidden Helm-owned RBAC handoff text: ${literal}"
  fi
}

resource_block() {
  local resource_type="$1"
  local resource_name="$2"
  sed -n "/resource \"${resource_type}\" \"${resource_name}\" {/,/^}/p" "${main}"
}

# Adoption imports only the namespace, authentication ConfigMap and the two
# Helm releases. No Role, RoleBinding, ClusterRole or ClusterRoleBinding may be
# imported from a Helm stored manifest.
import_targets="$({
  awk '
    /^import \{/ { in_import = 1; next }
    in_import && /^[[:space:]]*to[[:space:]]*=/ { sub(/^[[:space:]]*/, ""); print }
    in_import && /^}/ { in_import = 0 }
  ' "${main}"
} | LC_ALL=C sort)"

expected_import_targets="$(printf '%s\n' \
  'to       = helm_release.substrate_application[0]' \
  'to       = helm_release.substrate_crds[0]' \
  'to       = kubernetes_config_map_v1.authentication[0]' \
  'to       = kubernetes_namespace_v1.substrate[0]' |
  LC_ALL=C sort)"

[[ "${import_targets}" == "${expected_import_targets}" ]] ||
  fail "adoption import targets differ from the four non-RBAC resources"

# Every Terraform-owned RBAC object uses a stable additive name. These names
# are distinct from the current Helm chart names and intentionally carry no
# organization prefix.
while read -r local_key stable_name; do
  require_regex "${main}" "^[[:space:]]*${local_key}[[:space:]]*=[[:space:]]*\"${stable_name}\"$"
done <<'EOF'
getter_role              kagent-control-plane-getter
getter_role_binding      kagent-control-plane-getter-binding
writer_role              kagent-control-plane-writer
writer_role_binding      kagent-control-plane-writer-binding
leader_role              kagent-control-plane-leader-election
leader_role_binding      kagent-control-plane-leader-election-binding
env_sources_role         kagent-substrate-env-source-reader
env_sources_role_binding kagent-substrate-env-source-reader-binding
api_role                 substrate-api-server-reader
api_role_binding         substrate-api-server-reader-binding
controller_role          substrate-controller-actortemplate
controller_role_binding  substrate-controller-actortemplate-binding
EOF

rbac_names_block="$(sed -n '/^[[:space:]]*rbac_names = {/,/^  }/p' "${main}")"
[[ "${rbac_names_block}" != *yourown* ]] || fail "RBAC resource names use the forbidden yourown prefix"

while read -r resource_type resource_name name_reference bootstrap_guard; do
  block="$(resource_block "${resource_type}" "${resource_name}")"
  [[ "${block}" == *"name      = ${name_reference}"* || "${block}" == *"name   = ${name_reference}"* ]] ||
    fail "${resource_type}.${resource_name} does not use ${name_reference}"
  [[ "${block}" == *"${bootstrap_guard}"* ]] ||
    fail "${resource_type}.${resource_name} is not derived from the bootstrap resource set"
done <<'EOF'
kubernetes_role_v1 kagent_getter local.rbac_names.kagent.getter_role for_each = var.bootstrap_enabled
kubernetes_role_v1 kagent_writer local.rbac_names.kagent.writer_role for_each = var.bootstrap_enabled
kubernetes_role_binding_v1 kagent_getter local.rbac_names.kagent.getter_role_binding for_each = kubernetes_role_v1.kagent_getter
kubernetes_role_binding_v1 kagent_writer local.rbac_names.kagent.writer_role_binding for_each = kubernetes_role_v1.kagent_writer
kubernetes_role_v1 kagent_leader_election local.rbac_names.kagent.leader_role for_each = var.bootstrap_enabled
kubernetes_role_binding_v1 kagent_leader_election local.rbac_names.kagent.leader_role_binding for_each = kubernetes_role_v1.kagent_leader_election
kubernetes_role_v1 kagent_env_sources local.rbac_names.kagent.env_sources_role for_each = var.bootstrap_enabled
kubernetes_role_binding_v1 kagent_env_sources local.rbac_names.kagent.env_sources_role_binding for_each = kubernetes_role_v1.kagent_env_sources
kubernetes_cluster_role_v1 substrate_api local.rbac_names.substrate.api_role count = var.bootstrap_enabled
kubernetes_cluster_role_binding_v1 substrate_api local.rbac_names.substrate.api_role_binding count = var.bootstrap_enabled
kubernetes_cluster_role_v1 substrate_controller local.rbac_names.substrate.controller_role count = var.bootstrap_enabled
kubernetes_cluster_role_binding_v1 substrate_controller local.rbac_names.substrate.controller_role_binding count = var.bootstrap_enabled
EOF

# Subjects remain exactly the service accounts used by the Helm releases.
for resource_name in kagent_getter kagent_writer kagent_leader_election; do
  block="$(resource_block kubernetes_role_binding_v1 "${resource_name}")"
  [[ "${block}" == *'name      = "kagent-controller"'* ]] || fail "${resource_name} subject changed"
done

block="$(resource_block kubernetes_role_binding_v1 kagent_env_sources)"
[[ "${block}" == *'name      = "ate-api-server"'* ]] || fail "kagent env-source subject changed"

block="$(resource_block kubernetes_cluster_role_binding_v1 substrate_api)"
[[ "${block}" == *'name      = "ate-api-server"'* ]] || fail "Substrate API subject changed"

block="$(resource_block kubernetes_cluster_role_binding_v1 substrate_controller)"
[[ "${block}" == *'name      = "ate-controller"'* ]] || fail "Substrate controller subject changed"

forbid_literal "${main}" '"helm.sh/resource-policy" = "keep"'
forbid_literal "${main}" 'toset(["ate-api-server-role"])'
forbid_literal "${main}" 'toset(["ate-api-server-binding"])'

for old_kagent_name in \
  kagent-getter-role \
  kagent-getter-rolebinding \
  kagent-writer-role \
  kagent-writer-rolebinding \
  kagent-leader-election-role \
  kagent-leader-election-rolebinding \
  kagent-ate-api-env-sources; do
  forbid_literal "${main}" "\"${old_kagent_name}\""
done

require_literal "${module_outputs}" 'output "rbac_names"'
require_literal "${module_outputs}" 'value       = local.rbac_names'
require_literal "${stack_outputs}" 'output "kagent_substrate_rbac_names"'
require_literal "${stack_outputs}" 'value       = component.substrate_prerequisites.rbac_names'

for doc in "${release_doc}" "${chart_readme}"; do
  require_literal "${doc}" 'Existing Helm-owned RBAC'
  require_literal "${doc}" 'parallel'
  forbid_literal "${doc}" '`helm.sh/resource-policy=keep`'
done

printf 'parallel RBAC handoff tests passed\n'
