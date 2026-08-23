#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cloudflare_dir="$(cd "$script_dir/.." && pwd)"
service_inputs="$cloudflare_dir/service-inputs.tfdeploy.hcl"
deployment="$cloudflare_dir/cloudflare.tfdeploy.hcl"
zero_trust_module="$cloudflare_dir/modules/zero-trust/main.tf"

fail() {
  echo "kagent Cloudflare route test failed: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local value="$2"
  rg -Fq -- "$value" "$file" || fail "$file is missing: $value"
}

require_literal "$service_inputs" 'kagent = {'
require_literal "$service_inputs" 'enabled   = true'
require_literal "$service_inputs" 'namespace = "kagent-system"'
require_literal "$service_inputs" 'service   = "kagent-ui"'
require_literal "$service_inputs" 'port      = 8080'

require_literal "$deployment" 'for hostname, route in local.private_http_routes :'
require_literal "$deployment" 'hostname => "http://${route.service}.${route.namespace}.svc.cluster.local:${route.port}"'
require_literal "$deployment" 'if route.enabled'
require_literal "$deployment" 'domain               = "yourown.chat"'

require_literal "$zero_trust_module" 'resource "cloudflare_zero_trust_access_application" "this"'
require_literal "$zero_trust_module" 'for_each = var.upstreams'
require_literal "$zero_trust_module" 'domain           = "${each.key}.${var.domain}"'

terraform -chdir="$cloudflare_dir" fmt -check -recursive >/dev/null

echo "kagent Cloudflare route test passed"
