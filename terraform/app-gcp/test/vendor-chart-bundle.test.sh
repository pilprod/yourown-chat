#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
repo_dir="$(cd "$app_dir/../.." && pwd)"
module_dir="$app_dir/modules/vendor-chart-bundle"
main="$module_dir/main.tf"
variables="$module_dir/variables.tf"
outputs="$module_dir/outputs.tf"
components="$app_dir/components.tfcomponent.hcl"
deployment="$app_dir/app.tfdeploy.hcl"
service_inputs="$app_dir/service-inputs.tfdeploy.hcl"
platform_dir="$(cd "$app_dir/../platform-gcp" && pwd)"
edge_deployment="$app_dir/../cloudflare/cloudflare.tfdeploy.hcl"
platform_service_inputs="$platform_dir/service-inputs.tfdeploy.hcl"
edge_service_inputs="$app_dir/../cloudflare/service-inputs.tfdeploy.hcl"

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
if rg -ni -- "$forbidden_vendor" "$module_dir" "$0" "$components" "$deployment"; then
  fail "the public adapter contains a vendor-specific name"
fi

require_literal "$deployment" 'vendor_chart_bundles   = local.vendor_chart_bundles'
require_literal "$service_inputs" 'vendor_chart_bundles = {'
require_literal "$components" 'component "vendor_chart_bundle"'
require_literal "$components" 'source = "./modules/vendor-chart-bundle"'
require_literal "$components" 'for_each = var.vendor_chart_bundles'
require_literal "$components" 'bundle_key          = each.key'
require_literal "$components" 'database_secret_ids = var.additional_cloudsql_connection_secret_ids'
require_literal "$platform_dir/platform.tfdeploy.hcl" 'additional_database_users = local.additional_database_users'
require_literal "$platform_service_inputs" 'additional_database_users = {'
require_literal "$platform_dir/outputs.tfcomponent.hcl" 'output "additional_cloudsql_connection_secret_ids"'
require_literal "$edge_deployment" 'for hostname, route in local.private_http_routes :'
require_literal "$edge_service_inputs" 'private_http_routes = {'

if rg -n -- 'upstream_input\.catalog|service-catalog' \
  "$deployment" "$service_inputs" "$components" \
  "$platform_dir/platform.tfdeploy.hcl" "$platform_service_inputs" \
  "$edge_deployment" "$edge_service_inputs"; then
  fail "service inputs must live in the existing Stacks without a service-catalog dependency"
fi

require_literal "$main" 'chart     = var.bundle.charts.crds.ref'
require_literal "$main" 'chart     = var.bundle.charts.application.ref'
require_literal "$variables" 'can(regex("^oci://[^@]+@sha256:[0-9a-f]{64}$", chart.ref))'
require_literal "$variables" 'length(var.bundle.image_digests) > 0'
require_literal "$variables" 'values_path   = string'
require_literal "$variables" '^helm/vendor/'
require_literal "$variables" 'startswith(chart.values_path, "helm/vendor/${var.bundle_key}/")'
require_literal "$main" 'repository_root         = abspath("${path.module}/../../../..")'
require_literal "$main" 'crd_values              = try(file(local.crd_values_path), "")'
require_literal "$main" 'application_values      = try(file(local.application_values_path), "")'
require_literal "$main" 'fileexists(local.crd_values_path) && sha256(local.crd_values) == var.bundle.charts.crds.values_sha256'
require_literal "$main" 'fileexists(local.application_values_path) && sha256(local.application_values) == var.bundle.charts.application.values_sha256'
require_literal "$main" 'strcontains(local.application_values, digest)'
require_literal "$outputs" 'fileexists(local.crd_values_path) && sha256(local.crd_values) == var.bundle.charts.crds.values_sha256'
require_literal "$outputs" 'fileexists(local.application_values_path) && sha256(local.application_values) == var.bundle.charts.application.values_sha256'
require_literal "$outputs" 'startswith(chart.values_path, "helm/vendor/${var.bundle_key}/")'
require_literal "$outputs" 'strcontains(local.application_values, digest)'
require_literal "$main" 'prevent_destroy = true'

opaque_values_key="$(printf '%s%s' 'values_' 'base64')"
opaque_values_decoder="$(printf '%s%s' 'base64decode(var.bundle.' 'charts')"
if rg -n -F -- "$opaque_values_key" "$module_dir" "$service_inputs" "$app_dir/variables.tfcomponent.hcl" || \
  rg -n -F -- "$opaque_values_decoder" "$module_dir"; then
  fail "Helm values must be readable tracked files, not opaque base64 deployment inputs"
fi

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

bundle_keys() {
  awk '
    $0 == "  vendor_chart_bundles = {" { in_bundles = 1; next }
    in_bundles && $0 == "  }" { exit }
    in_bundles && $0 ~ /^    [a-z0-9][-a-z0-9]* = \{$/ {
      key = $0
      sub(/^    /, "", key)
      sub(/ = \{$/, "", key)
      print key
    }
  ' "$service_inputs"
}

bundle_chart_records() {
  local target_bundle="$1"

  awk -v target="$target_bundle" '
    $0 == "  vendor_chart_bundles = {" { in_bundles = 1; next }
    in_bundles && $0 == "  }" { exit }
    in_bundles && $0 ~ /^    [a-z0-9][-a-z0-9]* = \{$/ {
      bundle = $0
      sub(/^    /, "", bundle)
      sub(/ = \{$/, "", bundle)
      chart = ""
      next
    }
    bundle == target && $0 ~ /^        (crds|application) = \{$/ {
      chart = $0
      sub(/^        /, "", chart)
      sub(/ = \{$/, "", chart)
      next
    }
    bundle == target && chart != "" && $0 ~ /^          values_path[[:space:]]*=/ {
      split($0, parts, "\"")
      path = parts[2]
      next
    }
    bundle == target && chart != "" && $0 ~ /^          values_sha256[[:space:]]*=/ {
      split($0, parts, "\"")
      print chart "\t" path "\t" parts[2]
      chart = ""
      path = ""
    }
  ' "$service_inputs"
}

bundle_image_digests() {
  local target_bundle="$1"

  awk -v target="$target_bundle" '
    $0 == "  vendor_chart_bundles = {" { in_bundles = 1; next }
    in_bundles && $0 == "  }" { exit }
    in_bundles && $0 ~ /^    [a-z0-9][-a-z0-9]* = \{$/ {
      bundle = $0
      sub(/^    /, "", bundle)
      sub(/ = \{$/, "", bundle)
      in_images = 0
      next
    }
    bundle == target && $0 == "      image_digests = {" { in_images = 1; next }
    bundle == target && in_images && $0 == "      }" { in_images = 0; next }
    bundle == target && in_images {
      if (match($0, /sha256:[0-9a-f]{64}/)) {
        print substr($0, RSTART, RLENGTH)
      }
    }
  ' "$service_inputs"
}

values_path_owned_by_bundle() {
  local bundle_key="$1"
  local relative_path="$2"

  [[ "$relative_path" == "helm/vendor/$bundle_key/"*.values.yaml ]]
}

if values_path_owned_by_bundle bundle-one helm/vendor/bundle-two/application.values.yaml; then
  fail "cross-bundle values path ownership test did not fail closed"
fi

bundle_count=0
while IFS= read -r bundle_key; do
  [[ -n "$bundle_key" ]] || continue
  bundle_count=$((bundle_count + 1))
  chart_count=0
  application_values=""

  while IFS=$'\t' read -r chart_name relative_path declared_hash; do
    [[ -n "$chart_name" && -n "$relative_path" && -n "$declared_hash" ]] || \
      fail "incomplete chart values record for bundle $bundle_key"
    chart_count=$((chart_count + 1))
    values_path_owned_by_bundle "$bundle_key" "$relative_path" || \
      fail "$relative_path is not owned by bundle $bundle_key"
    values_file="$repo_dir/$relative_path"
    [[ -f "$values_file" ]] || fail "missing tracked Helm values file: ${values_file#$repo_dir/}"
    [[ "$declared_hash" =~ ^[0-9a-f]{64}$ ]] || fail "missing checksum for $relative_path"
    actual_hash="$(sha256_file "$values_file")"
    [[ "$actual_hash" == "$declared_hash" ]] || fail "$relative_path does not match its declared checksum"
    if [[ "$chart_name" == "application" ]]; then
      application_values="$values_file"
    fi
  done < <(bundle_chart_records "$bundle_key")

  [[ "$chart_count" -eq 2 ]] || fail "bundle $bundle_key must declare exactly two tracked values files"
  [[ -n "$application_values" ]] || fail "bundle $bundle_key is missing application values"

  image_count=0
  while IFS= read -r image_digest; do
    [[ -n "$image_digest" ]] || continue
    image_count=$((image_count + 1))
    require_literal "$application_values" "$image_digest"
  done < <(bundle_image_digests "$bundle_key")
  [[ "$image_count" -gt 0 ]] || fail "bundle $bundle_key must declare at least one image digest"
done < <(bundle_keys)

[[ "$bundle_count" -gt 0 ]] || fail "service inputs must declare at least one vendor chart bundle"

require_literal "$main" 'policy_types = ["Ingress", "Egress"]'
require_literal "$main" 'cidr = "${var.cluster_dns_ip}/32"'
require_literal "$main" 'port     = "53"'
require_literal "$main" 'protocol = "TCP"'
require_literal "$main" 'protocol = "UDP"'
require_literal "$main" '"kubernetes.io/metadata.name" = "kube-system"'
require_literal "$main" 'key      = "k8s-app"'
require_literal "$main" 'operator = "In"'
require_literal "$main" 'values   = ["kube-dns", "node-local-dns"]'

if rg -n -- 'data "kubernetes_endpoints_v1" "dns"|cluster_dns_(subsets|endpoint_ips)|dns_endpoint|The kube-dns Endpoints resource' "$main"; then
  fail "DNS egress must use DNS pod selectors, not endpoint ipBlocks or an endpoint-readiness precondition"
fi

require_literal "$main" 'resource "kubernetes_network_policy_v1" "flow_ingress"'
require_literal "$main" 'resource "kubernetes_network_policy_v1" "flow_egress"'
require_literal "$main" 'data "kubernetes_service_v1" "api"'
require_literal "$main" 'data "kubernetes_endpoints_v1" "api"'
require_literal "$main" 'kubernetes_api_service_ip = try(data.kubernetes_service_v1.api[0].spec[0].cluster_ip, null)'
require_literal "$main" 'for port in subset.port : port.port == 443 && port.protocol == "TCP"'
require_literal "$main" 'for_each = local.kubernetes_api_destination_ips'
require_literal "$main" 'cidr = "${api_destination.value}/32"'
require_literal "$main" 'condition     = length(local.kubernetes_api_endpoint_ips) > 0'
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
