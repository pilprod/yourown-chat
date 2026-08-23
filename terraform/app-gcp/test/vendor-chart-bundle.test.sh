#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
module_dir="$app_dir/modules/vendor-chart-bundle"
main="$module_dir/main.tf"
variables="$module_dir/variables.tf"
components="$app_dir/components.tfcomponent.hcl"
deployment="$app_dir/app.tfdeploy.hcl"
platform_dir="$(cd "$app_dir/../platform-gcp" && pwd)"
edge_deployment="$app_dir/../cloudflare/cloudflare.tfdeploy.hcl"

fail() {
  echo "vendor chart bundle adapter test failed: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local value="$2"
  rg -Fq -- "$value" "$file" || fail "$file is missing: $value"
}

for file in main.tf variables.tf outputs.tf versions.tf README.md; do
  [[ -f "$module_dir/$file" ]] || fail "missing module file: $file"
done

forbidden_vendor="$(printf '%s%s' 'ka' 'gent')"
if rg -ni -- "$forbidden_vendor" "$module_dir" "$0" "$components" "$deployment" "$platform_dir" "$edge_deployment"; then
  fail "the public adapter contains a vendor-specific name"
fi

require_literal "$deployment" 'key => repository if key != "catalog_contract"'
require_literal "$deployment" 'upstream_input.catalog.source_repositories.catalog_contract.remote_uri'
require_literal "$deployment" ').vendor_chart_bundles'
require_literal "$components" 'component "vendor_chart_bundle"'
require_literal "$components" 'source = "./modules/vendor-chart-bundle"'
require_literal "$components" 'for_each = var.vendor_chart_bundles'
require_literal "$components" 'bundle_key          = each.key'
require_literal "$components" 'database_secret_ids = var.additional_cloudsql_connection_secret_ids'
require_literal "$platform_dir/platform.tfdeploy.hcl" 'upstream_input.catalog.source_repositories.catalog_contract.remote_uri'
require_literal "$platform_dir/platform.tfdeploy.hcl" ').additional_database_users'
require_literal "$platform_dir/outputs.tfcomponent.hcl" 'output "additional_cloudsql_connection_secret_ids"'
require_literal "$edge_deployment" 'upstream_input.catalog.source_repositories.catalog_contract.remote_uri'
require_literal "$edge_deployment" ').private_http_routes, {}) :'

require_literal "$main" 'chart     = var.bundle.charts.crds.ref'
require_literal "$main" 'chart     = var.bundle.charts.application.ref'
require_literal "$variables" 'can(regex("^oci://[^@]+@sha256:[0-9a-f]{64}$", chart.ref))'
require_literal "$variables" 'strcontains(base64decode(var.bundle.charts.application.values_base64), digest)'
require_literal "$variables" 'length(var.bundle.image_digests) > 0'
require_literal "$main" 'crd_values         = base64decode(var.bundle.charts.crds.values_base64)'
require_literal "$main" 'application_values = base64decode(var.bundle.charts.application.values_base64)'
require_literal "$main" 'condition     = sha256(local.crd_values) == var.bundle.charts.crds.values_sha256'
require_literal "$main" 'condition     = sha256(local.application_values) == var.bundle.charts.application.values_sha256'
require_literal "$main" 'prevent_destroy = true'

require_literal "$main" 'policy_types = ["Ingress", "Egress"]'
require_literal "$main" 'cidr = "${var.cluster_dns_ip}/32"'
require_literal "$main" 'port     = "53"'
require_literal "$main" 'protocol = "TCP"'
require_literal "$main" 'protocol = "UDP"'
require_literal "$main" '"kubernetes.io/metadata.name" = "kube-system"'
require_literal "$main" '"k8s-app" = "kube-dns"'
require_literal "$main" 'resource "kubernetes_network_policy_v1" "flow_ingress"'
require_literal "$main" 'resource "kubernetes_network_policy_v1" "flow_egress"'
require_literal "$main" 'data "kubernetes_service_v1" "api"'
require_literal "$main" 'cidr = "${data.kubernetes_service_v1.api[0].spec[0].cluster_ip}/32"'
require_literal "$main" 'port     = "443"'
require_literal "$main" 'cidr = "${var.cloudsql_private_ip}/32"'
require_literal "$main" 'port     = tostring(each.value.port)'

require_literal "$main" 'kind       = "SecretProviderClass"'
require_literal "$main" 'provider = "gke"'
require_literal "$main" 'resourceName = "projects/${var.project_id}/secrets/${var.database_secret_ids[each.value.secret_id_key]}/versions/latest"'
require_literal "$main" 'application_ready = local.provisioned && var.bundle.application_enabled && local.database_bindings_ready'
require_literal "$main" 'kubernetes_manifest.database_secret_provider_class,'
require_literal "$main" 'kubernetes_network_policy_v1.database_egress,'
require_literal "$main" 'kubernetes_network_policy_v1.flow_egress,'
require_literal "$main" 'kubernetes_network_policy_v1.flow_ingress,'
require_literal "$main" 'kubernetes_network_policy_v1.kubernetes_api_egress,'
require_literal "$main" 'atomic            = false'
require_literal "$main" 'cleanup_on_fail   = false'
require_literal "$main" 'replace           = false'
require_literal "$main" 'reuse_values      = false'

if rg -n -- 'repository[[:space:]]*=' "$main"; then
  fail "OCI charts must be selected directly by their digest-bearing ref"
fi

if rg -n -- '0\.0\.0\.0/0|::/0|type[[:space:]]*=[[:space:]]*"(LoadBalancer|NodePort)"' "$module_dir"; then
  fail "the adapter contains a broad network path"
fi

terraform -chdir="$module_dir" fmt -check -recursive >/dev/null

echo "vendor chart bundle adapter test passed"
