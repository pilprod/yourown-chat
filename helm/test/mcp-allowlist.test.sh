#!/usr/bin/env bash
set -euo pipefail

# The Terraform Stacks MCP is policy-constrained by environment allowlists.
# This test pins the security-relevant values rendered into the production
# Deployment so a values change cannot silently widen or narrow them.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
render_file="$(mktemp)"
trap 'rm -f "${render_file}"' EXIT

helm template mcp "${repo_root}/helm/mcp" \
  --namespace mcp-terraform-stacks \
  --set mcp_terraform_stacks_image=example.invalid/terraform-stacks@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set mcp_google_cloud_image=example.invalid/google-cloud@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set mcp_tunnel_image=example.invalid/cloudflared@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set mcp_secret_project=test \
  --set mcp_google_cloud_gsa=google-cloud@example.invalid \
  --set mcp_terraform_stacks_gsa=terraform-stacks@example.invalid \
  --set mcp_tunnel_gsa=tunnel@example.invalid > "${render_file}"

env_value() {
  # Prints the rendered value of one container environment variable.
  awk -v name="$1" '
    $1 == "-" && $2 == "name:" && $3 == name { found = 1; next }
    found && $1 == "value:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }
  ' "${render_file}"
}

# Exactly the approved Stack names, in the committed order; nothing else.
[[ "$(env_value TFE_STACK_ALLOWLIST)" == "cloudflare,app-gcp,platform-gcp,agent-registry-gcp,service-catalog" ]]

# Exactly the public platform repository plus the private service catalog.
[[ "$(env_value TFE_STACK_REPOSITORY_ALLOWLIST)" == "pilprod/yourown-chat,pilprod/yourown-chat-catalog" ]]

# The remaining guardrails are unchanged by the allowlist widening.
[[ "$(env_value TFE_STACK_PROJECT_ALLOWLIST)" == "prj-QuYKhn6EzLX9jB53" ]]
[[ "$(env_value TFE_STACK_DIRECTORY_PREFIX_ALLOWLIST)" == "terraform/" ]]
[[ "$(env_value TFE_STACK_GITHUB_APP_INSTALLATION_ID)" == "ghain-PoBaBziU2edUHeaR" ]]

# Each allowlist is rendered exactly once (one Terraform Stacks container).
[[ "$(grep -Fc 'name: TFE_STACK_ALLOWLIST' "${render_file}")" == 1 ]]
[[ "$(grep -Fc 'name: TFE_STACK_REPOSITORY_ALLOWLIST' "${render_file}")" == 1 ]]

printf 'Terraform MCP allowlist rendering tests passed\n'
