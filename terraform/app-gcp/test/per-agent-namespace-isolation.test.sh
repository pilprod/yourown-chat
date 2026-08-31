#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
repo_root="$(cd "${app_dir}/../.." && pwd -P)"
components="${app_dir}/components.tfcomponent.hcl"
service_inputs="${app_dir}/service-inputs.tfdeploy.hcl"
prerequisites="${app_dir}/modules/substrate-prerequisites"
vendor_bundle="${app_dir}/modules/vendor-chart-bundle/main.tf"
platform_dir="${repo_root}/terraform/platform-gcp"

fail() {
  printf 'per-agent namespace isolation test failed: %s\n' "$*" >&2
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
    fail "${file} still contains: ${literal}"
  fi
}

forbidden_terraform_literal() {
  local directory="$1"
  local literal="$2"
  if rg -Fq --glob '*.tf' --glob '*.hcl' -- "${literal}" "${directory}"; then
    fail "${directory} Terraform still contains: ${literal}"
  fi
}

# The retired worker rail has no live Stack input, component, namespace,
# scheduling, identity, bucket or delivery resource left to turn back on.
for legacy_literal in \
  'yourown-agents' \
  'agent_platform_enabled' \
  'agent_platform_runtime_enabled' \
  'agent_results_bucket' \
  'clouddeploy_agents_start' \
  'clouddeploy_agents_pause'; do
  forbidden_terraform_literal "${app_dir}" "${legacy_literal}"
done

for legacy_literal in \
  'yourown-agents' \
  'agents-workflow' \
  'agents-activity' \
  'workload_identity_agents' \
  'workload_identity_agent_workflow' \
  'temporal_results_bucket_name' \
  'agent_results_retention_days'; do
  forbidden_terraform_literal "${platform_dir}" "${legacy_literal}"
done

if find "${repo_root}/helm/agent-platform" -type f -print -quit 2>/dev/null | grep -q .; then
  fail "legacy agent Helm chart still contains tracked content"
fi
test ! -e "${repo_root}/helm/skaffold-agents.yaml" || fail "legacy agent Skaffold rail still exists"
test ! -e "${repo_root}/helm/agent-pilot.sh" || fail "legacy agent pilot helper still exists"

# One declarative workload namespace is admitted initially. The stable map key
# is the agent ID; the Kubernetes name deliberately carries no product prefix.
require_literal "${service_inputs}" 'codex   = { name = "agent-codex", quota_profile = "testbed-workload" }'
require_literal "${service_inputs}" 'namespace_key = "codex"'
forbidden_literal "${service_inputs}" 'workload = { name = "kagent-testbed"'

require_literal "${components}" 'agent_namespaces = {'
require_literal "${components}" 'if namespace.quota_profile == "testbed-workload"'
require_literal "${prerequisites}/variables.tf" 'variable "agent_namespaces"'
require_literal "${prerequisites}/variables.tf" 'length(distinct(values(var.agent_namespaces))) == length(var.agent_namespaces)'
require_literal "${prerequisites}/main.tf" '{ control = local.kagent_namespace }'

# Getter/writer controller permissions and the existing ate-api environment
# source permission must follow the same per-agent namespace map.
[[ "$(rg -Fc 'for_each = var.bootstrap_enabled ? local.kagent_namespaces : {}' "${prerequisites}/main.tf")" -eq 3 ]] ||
  fail "all three namespace-scoped RBAC families must iterate kagent_namespaces"
require_literal "${prerequisites}/main.tf" 'namespace = each.value.metadata[0].namespace'

# The generic namespace owner applies the isolation baseline to every map
# entry, including the initial Codex agent namespace.
require_literal "${vendor_bundle}" '"pod-security.kubernetes.io/enforce"         = "restricted"'
require_literal "${vendor_bundle}" 'resource "kubernetes_network_policy_v1" "default_deny"'
require_literal "${vendor_bundle}" 'policy_types = ["Ingress", "Egress"]'
require_literal "${vendor_bundle}" 'resource "kubernetes_network_policy_v1" "dns_egress"'

for values in \
  "${repo_root}/helm/vendor/kagent/application.values.yaml" \
  "${repo_root}/helm/kagent/kagent.values.yaml"; do
  require_literal "${values}" '    - agent-codex'
  require_literal "${values}" 'host: http://model-fixture.agent-codex.svc.cluster.local:11434'
  forbidden_literal "${values}" 'kagent-testbed'
done

declared_sha="$(sed -n '/values_path   = "helm\/vendor\/kagent\/application.values.yaml"/{n;s/.*values_sha256 = "\([0-9a-f]*\)".*/\1/p;}' "${service_inputs}")"
actual_sha="$(shasum -a 256 "${repo_root}/helm/vendor/kagent/application.values.yaml" | awk '{print $1}')"
[[ "${declared_sha}" == "${actual_sha}" ]] || fail "vendor kagent values checksum is stale"

printf 'per-agent namespace isolation tests passed\n'
