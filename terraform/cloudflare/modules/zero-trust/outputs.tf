output "tunnel_token" {
  description = "cloudflared run token. Written to Secret Manager by the stack (zero_trust_secrets component) and materialised in-cluster by app-gcp; never leaves Secret Manager/etcd otherwise."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
  sensitive   = true
}

output "hostnames" {
  description = "Access-protected hostnames whose self-hosted applications, DNS records and Tunnel ingress have been applied."
  value       = sort([for application in cloudflare_zero_trust_access_application.this : application.domain])

  depends_on = [
    cloudflare_zero_trust_tunnel_cloudflared_config.this,
    cloudflare_dns_record.this,
  ]
}

output "mcp_portal_url" {
  description = "Single Managed OAuth endpoint for Claude, ChatGPT and other remote MCP clients."
  value       = "https://${cloudflare_zero_trust_access_ai_controls_mcp_portal.this.hostname}/mcp"
}

output "mcp_portal_hostname" {
  description = "Hostname secured by the explicitly managed Portal Access application."
  value       = cloudflare_zero_trust_access_ai_controls_mcp_portal.this.hostname
}

output "mcp_server_ids" {
  description = "Stable Cloudflare AI Controls MCP server IDs."
  value       = { for name, server in cloudflare_zero_trust_access_ai_controls_mcp_server.this : name => server.id }
}
