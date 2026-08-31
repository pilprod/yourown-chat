#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cloudflare_dir="$(cd "$script_dir/.." && pwd)"
service_inputs="$cloudflare_dir/service-inputs.tfdeploy.hcl"
deployment="$cloudflare_dir/cloudflare.tfdeploy.hcl"
components="$cloudflare_dir/components.tfcomponent.hcl"
component_variables="$cloudflare_dir/variables.tfcomponent.hcl"
zero_trust_module="$cloudflare_dir/modules/zero-trust/main.tf"
zero_trust_variables="$cloudflare_dir/modules/zero-trust/variables.tf"
cloudflare_docs="$(cd "$cloudflare_dir/../.." && pwd)/docs/CLOUDFLARE.md"

fail() {
  echo "kagent Cloudflare route test failed: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local value="$2"
  rg -Fq -- "$value" "$file" || fail "$file is missing: $value"
}

require_literal_block() {
  local file="$1"
  local value="$2"
  rg --multiline -Fq -- "$value" "$file" || fail "$file is missing the expected route block"
}

forbid_literal() {
  local file="$1"
  local value="$2"
  if rg -Fq -- "$value" "$file"; then
    fail "$file must not contain: $value"
  fi
}

require_literal_block "$service_inputs" $'"dev.kagent" = {\n      enabled   = true\n      namespace = "kagent-dev"\n      service   = "kagent-ui"\n      port      = 8080\n    }'
require_literal_block "$service_inputs" $'kagent = {\n      enabled   = true\n      namespace = "kagent-system"\n      service   = "kagent-ui"\n      port      = 8080\n    }'
require_literal "$service_inputs" 'enabled   = true'
require_literal "$service_inputs" 'service   = "kagent-ui"'
require_literal "$service_inputs" 'port      = 8080'
forbid_literal "$service_inputs" 'service   = "kagent-ui-dev"'
forbid_literal "$service_inputs" 'service   = "kagent-ui-prod"'

require_literal "$deployment" 'for hostname, route in local.private_http_routes :'
require_literal "$deployment" 'hostname => "http://${route.service}.${route.namespace}.svc.cluster.local:${route.port}"'
require_literal "$deployment" 'if route.enabled'
require_literal "$deployment" 'domain               = "yourown.chat"'
require_literal "$deployment" 'zero_trust_advanced_certificate_enabled = false'

require_literal "$components" 'advanced_certificate_manager_enabled = var.zero_trust_advanced_certificate_enabled'
require_literal_block "$component_variables" $'variable "zero_trust_advanced_certificate_enabled" {\n  type        = bool\n  description = "Fail-closed opt-in for the paid Advanced Certificate Manager pack covering deep Zero Trust upstream hostnames. Enable only after the zone entitlement and API-token SSL and Certificates permissions are confirmed."\n  default     = false\n}'

require_literal "$zero_trust_module" 'resource "cloudflare_zero_trust_access_application" "this"'
require_literal "$zero_trust_module" 'for_each = var.upstreams'
require_literal "$zero_trust_module" 'domain           = "${each.key}.${var.domain}"'
require_literal "$zero_trust_module" 'resource "cloudflare_certificate_pack" "deep_upstreams"'
require_literal "$zero_trust_module" 'for_each = var.advanced_certificate_manager_enabled && length(local.deep_upstream_hostnames) > 0 ? toset(["default"]) : toset([])'
require_literal "$zero_trust_module" 'if strcontains(label, ".")'
require_literal "$zero_trust_module" '[var.domain, "*.${var.domain}"]'
require_literal "$zero_trust_module" 'certificate_authority = "lets_encrypt"'
require_literal "$zero_trust_module" 'validation_method     = "txt"'
require_literal "$zero_trust_module" 'validity_days         = 90'
require_literal "$zero_trust_module" 'create_before_destroy = true'
forbid_literal "$zero_trust_module" 'resource "cloudflare_total_tls"'
require_literal_block "$zero_trust_variables" $'variable "advanced_certificate_manager_enabled" {\n  type        = bool\n  description = "Fail-closed opt-in for the paid Advanced Certificate Manager pack covering deep private-upstream hostnames. Enable only after the zone entitlement and API-token permissions are confirmed."\n  default     = false\n}'

require_literal "$cloudflare_docs" 'https://dev.kagent.yourown.chat'
require_literal "$cloudflare_docs" 'https://kagent.yourown.chat'
require_literal "$cloudflare_docs" 'Advanced Certificate Manager'
require_literal "$cloudflare_docs" 'current deployment input `zero_trust_advanced_certificate_enabled` are'
require_literal "$cloudflare_docs" 'cloudflare_certificate_pack.deep_upstreams["default"]'
require_literal "$cloudflare_docs" 'does not carry Agent Host, agentgateway, A2A, or Temporal traffic'

terraform -chdir="$cloudflare_dir" fmt -check -recursive >/dev/null

echo "kagent Cloudflare route test passed"
