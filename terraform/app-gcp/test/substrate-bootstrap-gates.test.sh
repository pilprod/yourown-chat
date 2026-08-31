#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
components="${app_dir}/components.tfcomponent.hcl"
variables="${app_dir}/variables.tfcomponent.hcl"
outputs="${app_dir}/outputs.tfcomponent.hcl"
service_inputs="${app_dir}/service-inputs.tfdeploy.hcl"
app_deploy="${app_dir}/app.tfdeploy.hcl"
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

require_literal_count() {
  local file="$1"
  local literal="$2"
  local expected="$3"
  local actual
  actual="$(rg -F -o -- "${literal}" "${file}" | wc -l | tr -d '[:space:]')"
  [[ "${actual}" == "${expected}" ]] || fail "${file} has ${actual} occurrences of ${literal}; expected ${expected}"
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
require_literal "${service_inputs}" 'external_broker_smoke_release      = ""'
require_literal "${service_inputs}" 'application_enabled = true'
require_literal "${app_deploy}" 'adopt_existing_substrate                         = false'
require_literal "${app_deploy}" 'adopt_existing_substrate_compatibility_confirmed = false'
require_literal "${variables}" 'variable "adopt_existing_substrate"'
require_literal "${variables}" 'variable "adopt_existing_substrate_compatibility_confirmed"'
require_literal "${variables}" 'var.adopt_existing_substrate &&'
require_literal "${variables}" 'var.kagent_substrate_delivery.bootstrap_enabled'
require_literal "${variables}" ') || var.adopt_existing_substrate_compatibility_confirmed'
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
require_literal "${components}" 'bootstrap_enabled                                = var.kagent_substrate_delivery.bootstrap_enabled'
require_literal "${components}" 'adopt_existing                                   = var.adopt_existing_substrate'
require_literal "${components}" 'adopt_existing_substrate_compatibility_confirmed = var.adopt_existing_substrate_compatibility_confirmed'
require_literal "${components}" 'release_enabled                                  = var.kagent_substrate_delivery.release_enabled'
require_literal "${components}" 'native_secret_sync_ready                         = var.kagent_substrate_delivery.native_secret_sync_ready'
require_literal "${components}" 'external_broker_smoke_ready                      = var.kagent_substrate_delivery.external_broker_smoke_ready'
require_literal "${components}" 'external_broker_smoke_release                    = var.kagent_substrate_delivery.external_broker_smoke_release'
require_literal "${components}" 'promotion_gate_reader_email                      = component.clouddeploy_kagent_substrate.cleanup_service_account_email'
require_literal_count "${components}" 'predeploy_actions = ["require-external-broker-smoke"]' 1
require_literal "${components}" 'cluster_dns_ip                                   = var.cluster_dns_ip'
require_literal "${components}" 'local_provider_only                              = var.kagent_substrate_delivery.local_provider_only'
require_literal "${components}" 'kagent_control_planes = {'
require_literal "${components}" 'substrate_application_chart = try('
require_literal "${components}" 'substrate_helm_set_values = try(var.kagent_substrate_delivery.helm_set_values["substrate"], {})'
require_literal "${components}" 'substrate_values_sha256   = try(var.kagent_substrate_delivery.values_sha256["kagent/substrate.values.yaml"], "")'
require_literal "${components}" 'public_ip_name             = var.agentgateway_public_ip_name == null ? "" : var.agentgateway_public_ip_name'
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
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_config_map_v1" "production_promotion_gate"'
require_literal "${prerequisites_dir}/main.tf" 'name      = "kagent-production-promotion-gate"'
require_literal "${prerequisites_dir}/main.tf" '"external_broker_smoke_ready" = tostring(var.external_broker_smoke_ready)'
require_literal "${prerequisites_dir}/main.tf" '"cloud_deploy_release"        = var.external_broker_smoke_release'
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_role_v1" "production_promotion_gate_reader"'
require_literal "${prerequisites_dir}/main.tf" 'resource_names = [kubernetes_config_map_v1.production_promotion_gate[0].metadata[0].name]'
require_literal "${prerequisites_dir}/main.tf" 'verbs          = ["get"]'
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_role_binding_v1" "production_promotion_gate_reader"'
require_literal "${prerequisites_dir}/main.tf" 'name      = var.promotion_gate_reader_email'
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_manifest" "agentgateway_parameters"'
require_literal "${prerequisites_dir}/main.tf" 'resource "helm_release" "substrate_application"'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.adopt_existing && var.bootstrap_enabled ? toset([local.substrate_namespace]) : toset([])'
require_literal "${prerequisites_dir}/main.tf" 'to       = kubernetes_namespace_v1.substrate[0]'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.adopt_existing && var.bootstrap_enabled ? toset(["${local.substrate_namespace}/substrate-crds"]) : toset([])'
require_literal "${prerequisites_dir}/main.tf" 'to       = helm_release.substrate_crds[0]'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.adopt_existing && var.bootstrap_enabled ? toset(["${local.substrate_namespace}/ate-api-authentication"]) : toset([])'
require_literal "${prerequisites_dir}/main.tf" 'to       = kubernetes_config_map_v1.authentication[0]'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.adopt_existing && var.bootstrap_enabled ? toset(["ate-api-server-role"]) : toset([])'
require_literal "${prerequisites_dir}/main.tf" 'to       = kubernetes_cluster_role_v1.substrate_api[0]'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.adopt_existing && var.bootstrap_enabled ? toset(["ate-api-server-binding"]) : toset([])'
require_literal "${prerequisites_dir}/main.tf" 'to       = kubernetes_cluster_role_binding_v1.substrate_api[0]'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.adopt_existing && var.bootstrap_enabled ? toset(["ate-controller"]) : toset([])'
require_literal "${prerequisites_dir}/main.tf" 'to       = kubernetes_cluster_role_v1.substrate_controller[0]'
require_literal "${prerequisites_dir}/main.tf" 'to       = kubernetes_cluster_role_binding_v1.substrate_controller[0]'
require_literal "${prerequisites_dir}/main.tf" 'for_each = var.adopt_existing && var.release_enabled ? toset(["${local.substrate_namespace}/substrate"]) : toset([])'
require_literal "${prerequisites_dir}/main.tf" 'to       = helm_release.substrate_application[0]'
require_literal "${prerequisites_dir}/variables.tf" 'variable "adopt_existing_substrate_compatibility_confirmed"'
require_literal "${prerequisites_dir}/variables.tf" 'var.adopt_existing &&'
require_literal "${prerequisites_dir}/variables.tf" 'var.bootstrap_enabled'
require_literal "${prerequisites_dir}/variables.tf" ') || var.adopt_existing_substrate_compatibility_confirmed'
require_literal "${prerequisites_dir}/main.tf" 'count = var.release_enabled ? 1 : 0'
require_literal "${prerequisites_dir}/main.tf" 'name             = "substrate"'
require_literal "${prerequisites_dir}/main.tf" 'skip_crds         = true'
require_literal "${prerequisites_dir}/main.tf" 'prevent_destroy = true'
require_literal "${prerequisites_dir}/main.tf" 'data "kubernetes_resource" "agentgateway_parameters"'
require_literal "${prerequisites_dir}/main.tf" 'data "kubernetes_resource" "substrate_api"'
require_literal "${prerequisites_dir}/main.tf" 'data "kubernetes_resource" "substrate_controller"'
require_literal "${prerequisites_dir}/main.tf" 'data "kubernetes_resource" "external_provider_gateway"'
require_literal "${prerequisites_dir}/main.tf" 'data "kubernetes_resource" "external_provider_tls_route"'
require_literal "${prerequisites_dir}/main.tf" 'api_version = "gateway.networking.k8s.io/v1"'
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_network_policy_v1" "substrate_verifier_controller_egress"'
require_literal "${prerequisites_dir}/main.tf" 'resource "kubernetes_network_policy_v1" "kagent_controller_verifier_ingress"'
require_literal "${prerequisites_dir}/main.tf" '"app.kubernetes.io/component" = "verify"'
require_literal "${prerequisites_dir}/main.tf" 'port     = "8083"'
require_literal "${prerequisites_dir}/main.tf" 'name      = "substrate-enrollment-admin-default-deny"'
require_literal "${prerequisites_dir}/main.tf" '"app.kubernetes.io/name"      = "substrate-enrollment-admin"'
require_literal "${prerequisites_dir}/main.tf" '"app.kubernetes.io/component" = "enrollment-admin"'
require_literal "${prerequisites_dir}/main.tf" 'policy_types = ["Ingress", "Egress"]'
require_literal "${prerequisites_dir}/main.tf" 'values   = ["ate-api-server", "ate-controller", "atenet-egress"]'
require_literal "${prerequisites_dir}/main.tf" 'cidr = "${var.cluster_dns_ip}/32"'
require_literal "${prerequisites_dir}/main.tf" 'protocol = "UDP"'
require_literal "${prerequisites_dir}/main.tf" 'protocol = "TCP"'
require_literal "${prerequisites_dir}/outputs.tf" 'output "bootstrap_ready"'
require_literal "${prerequisites_dir}/outputs.tf" 'try(helm_release.substrate_application[0].status == "deployed", false)'
require_literal "${prerequisites_dir}/outputs.tf" 'data.kubernetes_resource.agentgateway_parameters[0].object.metadata.name == "substrate-broker"'
require_literal "${prerequisites_dir}/outputs.tf" 'tonumber(data.kubernetes_resource.substrate_api[0].object.status.availableReplicas) >= 1'
require_literal "${prerequisites_dir}/outputs.tf" 'tonumber(data.kubernetes_resource.substrate_controller[0].object.status.availableReplicas) >= 1'
require_literal "${prerequisites_dir}/outputs.tf" 'data.kubernetes_resource.external_provider_gateway[0].object.metadata.name == "external-provider-broker"'
require_literal "${prerequisites_dir}/outputs.tf" 'data.kubernetes_resource.external_provider_tls_route[0].object.metadata.name == "external-provider-broker"'
require_literal "${prerequisites_dir}/outputs.tf" 'output "substrate_application_release"'
require_literal "${prerequisites_dir}/outputs.tf" 'output "external_broker_smoke_ready"'
require_literal "${prerequisites_dir}/outputs.tf" 'data["cloud_deploy_release"] != ""'
forbidden_literal "${prerequisites_dir}/main.tf" 'var.enabled'
forbidden_literal "${prerequisites_dir}/main.tf" 'condition     = var.native_secret_sync_ready'

authentication_block="$(sed -n '/resource "kubernetes_config_map_v1" "authentication" {/,/^}/p' "${prerequisites_dir}/main.tf")"
[[ "${authentication_block}" == *'kubernetes_service_account_v1.enrollment_admin'* ]] || fail "authentication ConfigMap can migrate the principal before the enrollment-admin ServiceAccount exists"
[[ "${authentication_block}" == *'prevent_destroy = true'* ]] || fail "authentication ConfigMap is missing prevent_destroy"

while read -r resource_type resource_name; do
  rbac_block="$(sed -n "/resource \"${resource_type}\" \"${resource_name}\" {/,/^}/p" "${prerequisites_dir}/main.tf")"
  [[ "${rbac_block}" == *'annotations = { "helm.sh/resource-policy" = "keep" }'* ]] || fail "${resource_type}.${resource_name} is missing the Helm keep annotation"
  [[ "${rbac_block}" == *'prevent_destroy = true'* ]] || fail "${resource_type}.${resource_name} is missing prevent_destroy"
done <<'EOF'
kubernetes_cluster_role_v1 substrate_api
kubernetes_cluster_role_binding_v1 substrate_api
kubernetes_cluster_role_v1 substrate_controller
kubernetes_cluster_role_binding_v1 substrate_controller
EOF
require_literal_count "${prerequisites_dir}/main.tf" '"helm.sh/resource-policy" = "keep"' 4

require_literal "${app_dir}/../../docs/KAGENT_SUBSTRATE_RELEASE.md" '`adopt_existing_substrate_compatibility_confirmed=true`'
require_literal "${app_dir}/../../docs/KAGENT_SUBSTRATE_RELEASE.md" '`substrate-crds-0.1.0-preview.20260830.1`'
require_literal "${app_dir}/../../helm/kagent/README.md" '`adopt_existing_substrate_compatibility_confirmed=true`'
require_literal "${app_dir}/../../helm/kagent/README.md" 'The checked-in application release remains disabled.'

verifier_egress_block="$(sed -n '/resource "kubernetes_network_policy_v1" "substrate_verifier_controller_egress" {/,/^}/p' "${prerequisites_dir}/main.tf")"
controller_ingress_block="$(sed -n '/resource "kubernetes_network_policy_v1" "kagent_controller_verifier_ingress" {/,/^}/p' "${prerequisites_dir}/main.tf")"
for block in "${verifier_egress_block}" "${controller_ingress_block}"; do
  [[ "${block}" == *'for_each = var.bootstrap_enabled ? var.kagent_control_planes : {}'* ]] || fail "verifier/controller policy is not generated for exact dev/prod control planes"
  [[ "${block}" == *'"app.kubernetes.io/component" = "verify"'* ]] || fail "verifier/controller policy is missing the exact verifier component label"
  [[ "${block}" == *'"app.kubernetes.io/part-of"   = "kagent-substrate-testbed"'* ]] || fail "verifier/controller policy is missing the exact verifier part-of label"
  [[ "${block}" == *'port     = "8083"'* ]] || fail "verifier/controller policy is missing controller TCP/8083"
  [[ "${block}" == *'protocol = "TCP"'* ]] || fail "verifier/controller policy is not TCP-only"
done

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
require_literal "${outputs}" 'component.substrate_prerequisites.external_broker_smoke_ready'

printf 'substrate bootstrap/release gate tests passed\n'
