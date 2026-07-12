# Cloudflare stack outputs — the human surface. All are gated with one([...])
# because the components only exist when public_ingress_enabled = true.

output "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for the managed domain."
  value       = one([for c in component.cloudflare : c.zone_id])
}

output "cloudflare_record_hostname" {
  type        = string
  description = "Fully-qualified hostname of the proxied apex A record."
  value       = one([for c in component.cloudflare : c.record_hostname])
}

output "cloudflare_origin_ip" {
  type        = string
  description = "IPv4 the proxied apex A record points at (echoes the platform ingress IP)."
  value       = one([for c in component.cloudflare : c.origin_ip])
}

output "cloudflare_dnssec" {
  type = object({
    status      = string
    ds          = string
    digest      = string
    key_tag     = string
    algorithm   = string
    digest_type = string
  })
  description = "DNSSEC DS material to publish at the registrar (null when dnssec disabled or no public ingress)."
  value       = one([for c in component.cloudflare : c.dnssec])
}

# --- Origin-protection secrets ------------------------------------------------
output "origin_secret_ids" {
  type        = map(string)
  description = "Logical name => Secret Manager secret ID for the origin-protection secrets (mattermost-origin-tls-cert/-key + cloudflare-origin-pull-ca). Empty when public_ingress_enabled = false."
  value       = one([for s in component.origin_secrets : s.secret_ids])
}
