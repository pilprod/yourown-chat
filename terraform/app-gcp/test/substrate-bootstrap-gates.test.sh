#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
components="${app_dir}/components.tfcomponent.hcl"
variables="${app_dir}/variables.tfcomponent.hcl"
outputs="${app_dir}/outputs.tfcomponent.hcl"
service_inputs="${app_dir}/service-inputs.tfdeploy.hcl"
prerequisites_dir="${app_dir}/modules/substrate-prerequisites"

fail() {
  printf 'substrate bootstrap gate test failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  rg -Fq -- "${literal}" "${file}" || fail "${file} is missing: ${literal}"
}

forbidden_literal() {
  local file="$1"
  local literal="$2"
  if rg -Fq -- "${literal}" "${file}"; then
    fail "${file} still contains forbidden legacy gate: ${literal}"
  fi
}

# The checked-in service input opens neither phase and never fabricates an
# operational attestation. Bootstrap is enabled only by a reviewed Stack input.
require_literal "${service_inputs}" 'bootstrap_enabled                  = false'
require_literal "${service_inputs}" 'release_enabled                    = false'
require_literal "${service_inputs}" 'local_provider_only                = true'
require_literal "${service_inputs}" 'native_secret_sync_ready           = false'
require_literal "${service_inputs}" 'crd_ownership_ready                = false'
require_literal "${service_inputs}" 'controller_namespace_handoff_ready = false'
require_literal "${service_inputs}" 'external_broker_smoke_ready        = false'
require_literal "${service_inputs}" 'application_enabled = true'
forbidden_literal "${service_inputs}" 'enabled                            = false'

# Phase A changes only the Terraform address of the still-managed kagent Helm
# release. Cloud Deploy stays closed until a later, separately applied
# destroy=false ownership-forget phase.
require_literal "${app_dir}/modules/vendor-chart-bundle/main.tf" 'from = helm_release.application'
require_literal "${app_dir}/modules/vendor-chart-bundle/main.tf" 'to   = helm_release.application_handoff_source'

# Bootstrap owns only prerequisites that must exist before native Secret sync.
require_literal "${variables}" 'bootstrap_enabled                  = optional(bool, false)'
require_literal "${variables}" 'release_enabled                    = optional(bool, false)'
require_literal "${variables}" 'var.kagent_substrate_delivery.bootstrap_enabled &&'
require_literal "${variables}" 'var.kagent_substrate_delivery.native_secret_sync_ready'
require_literal "${components}" 'var.kagent_substrate_delivery.bootstrap_enabled ? {'
require_literal "${components}" 'bootstrap_enabled          = var.kagent_substrate_delivery.bootstrap_enabled'
require_literal "${components}" 'release_enabled            = var.kagent_substrate_delivery.release_enabled'
require_literal "${components}" 'native_secret_sync_ready   = var.kagent_substrate_delivery.native_secret_sync_ready'
require_literal "${components}" 'cluster_dns_ip             = var.cluster_dns_ip'
require_literal "${components}" 'local_provider_only        = var.kagent_substrate_delivery.local_provider_only'
require_literal "${components}" 'kagent_control_planes = {'
require_literal "${components}" 'namespace    = var.vendor_chart_bundles["kagent"].namespaces["dev_control"].name'
require_literal "${components}" 'codex = var.vendor_chart_bundles["kagent"].namespaces["dev_codex"].name'
require_literal "${components}" 'source_secret_key = "actor_id_ca_pool"'
require_literal "${components}" 'kubernetes_name   = "actor-id-ca-certs"'
require_literal "${components}" 'keys              = ["ca.crt"]'
require_literal "${prerequisites_dir}/main.tf" 'count = var.bootstrap_enabled ? 1 : 0'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.bootstrap_enabled && !var.local_provider_only ? var.atenet_egress_destinations : {}'
require_literal "${prerequisites_dir}/variables.tf" '(var.local_provider_only && length(var.atenet_egress_destinations) == 0) ||'
require_literal "${prerequisites_dir}/variables.tf" '(!var.local_provider_only && length(var.atenet_egress_destinations) > 0)'
require_literal "${prerequisites_dir}/variables.tf" 'destination.cidr != "0.0.0.0/0"'
require_literal "${prerequisites_dir}/variables.tf" 'destination.cidr != "::/0"'
require_literal "${prerequisites_dir}/variables.tf" 'variable "kagent_control_planes"'
require_literal "${prerequisites_dir}/main.tf" 'for control_key, control in var.kagent_control_planes'
require_literal "${prerequisites_dir}/main.tf" 'var.local_provider_only ||'
require_literal "${prerequisites_dir}/main.tf" 'expected_derived_secret_contract'
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_network_policy_v1" "substrate_dns_egress"'
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_network_policy_v1" "enrollment_admin_default_deny"'
require_literal "${prerequisites_dir}/main.tf" 'name      = "substrate-enrollment-admin-default-deny"'
require_literal "${prerequisites_dir}/main.tf" '"app.kubernetes.io/name"      = "substrate-enrollment-admin"'
require_literal "${prerequisites_dir}/main.tf" '"app.kubernetes.io/component" = "enrollment-admin"'
require_literal "${prerequisites_dir}/main.tf" 'policy_types = ["Ingress", "Egress"]'
require_literal "${prerequisites_dir}/main.tf" 'values   = ["ate-api-server", "ate-controller", "atenet-egress"]'
require_literal "${prerequisites_dir}/main.tf" 'cidr = "${var.cluster_dns_ip}/32"'
require_literal "${prerequisites_dir}/main.tf" 'protocol = "UDP"'
require_literal "${prerequisites_dir}/main.tf" 'protocol = "TCP"'
require_literal "${prerequisites_dir}/outputs.tf" 'output "bootstrap_ready"'
forbidden_literal "${prerequisites_dir}/main.tf" 'var.enabled'
forbidden_literal "${prerequisites_dir}/main.tf" 'condition     = var.native_secret_sync_ready'

local_provider_contract_valid() {
  local local_only="$1"
  local destination_count="$2"
  [[ "${local_only}" == true && "${destination_count}" -eq 0 ]] ||
    [[ "${local_only}" == false && "${destination_count}" -gt 0 ]]
}

local_provider_contract_valid true 0 || fail "local-provider-only bootstrap must admit an empty egress set"
if local_provider_contract_valid false 0; then
  fail "false+empty must keep bootstrap closed"
fi
if local_provider_contract_valid true 1; then
  fail "local-provider-only mode must not admit Actor/MCP destinations"
fi
local_provider_contract_valid false 1 || fail "reviewed external egress mode must admit explicit destinations"

# The contract itself makes the second phase structurally dependent on the
# bootstrap phase and an explicit native Secret synchronization attestation.
require_literal "${variables}" '!var.kagent_substrate_delivery.release_enabled || ('
require_literal "${variables}" 'var.kagent_substrate_delivery.bootstrap_enabled &&'
require_literal "${outputs}" 'output "kagent_substrate_bootstrap_ready"'
require_literal "${outputs}" 'component.substrate_prerequisites.bootstrap_ready'
require_literal "${outputs}" 'component.substrate_prerequisites.release_ready'

printf 'substrate bootstrap/release gate tests passed\n'
