output "tunnel_token" {
  description = "cloudflared run token. Written to Secret Manager by the stack (zero_trust_secrets component) and materialised in-cluster by app-gcp; never leaves Secret Manager/etcd otherwise."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
  sensitive   = true
}

output "hostnames" {
  description = "Public hostnames routed onto the tunnel (one per upstream)."
  value       = [for k in keys(var.upstreams) : "${k}.${var.domain}"]
}

output "mcp_portal_url" {
  description = "Stable OAuth compatibility endpoint for Claude, ChatGPT, Codex and other remote MCP clients."
  value       = "https://mcp.${var.domain}/mcp"
}

output "mcp_portal_hostname" {
  description = "Internal Cloudflare Portal origin hostname secured by a service-token-only Access application."
  value       = cloudflare_zero_trust_access_ai_controls_mcp_portal.this.hostname
}

output "mcp_portal_service_token_id" {
  description = "Machine identity admitted by the Portal origin Access application."
  value       = cloudflare_zero_trust_access_service_token.ai_controls.id
}

output "mcp_server_ids" {
  description = "Stable Cloudflare AI Controls MCP server IDs."
  value       = { for name, server in cloudflare_zero_trust_access_ai_controls_mcp_server.this : name => server.id }
}
