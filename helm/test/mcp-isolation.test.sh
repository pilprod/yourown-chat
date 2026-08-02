#!/usr/bin/env bash
set -euo pipefail

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

# MCP backends have no public or node-level listener. The only externally
# reachable component is cloudflared, which establishes an outbound tunnel.
! grep -Eq 'type: (LoadBalancer|NodePort)' "${render_file}"
[[ "$(grep -Fc 'type: ClusterIP' "${render_file}")" == 2 ]]
grep -Fq 'name: default-deny-all' "${render_file}"
grep -Fq 'kubernetes.io/metadata.name: "mcp-tunnel"' "${render_file}"
grep -Fq 'app: mcp-tunnel' "${render_file}"

# Mattermost is deliberately not an allowed caller of an MCP Service. Its
# client traffic must pass through the public Cloudflare MCP Portal policy.
! grep -Fq 'kubernetes.io/metadata.name: "mattermost"' "${render_file}"

printf 'MCP isolation rendering tests passed\n'
