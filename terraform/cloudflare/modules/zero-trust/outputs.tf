output "tunnel_token" {
  description = "cloudflared run token. Written to Secret Manager by the stack (zero_trust_secrets component) and materialised in-cluster by app-gcp; never leaves Secret Manager/etcd otherwise."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.tunnel_token
  sensitive   = true
}

output "hostnames" {
  description = "Public hostnames routed onto the tunnel (one per upstream)."
  value       = [for k in keys(var.upstreams) : "${k}.${var.domain}"]
}
