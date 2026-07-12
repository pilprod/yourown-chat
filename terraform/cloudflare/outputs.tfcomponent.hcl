# Cloudflare stack outputs. The origin cert/key feed the LINKED app-gcp stack
# (publish_output in cloudflare.tfdeploy.hcl); the rest is the human surface.
# All are gated with one([...]) because the component only exists when
# public_ingress_enabled = true.

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

# --- Origin CA material for the app-gcp stack --------------------------------
output "origin_certificate_pem" {
  type        = string
  description = "Cloudflare Origin CA certificate (PEM). Null when manage_origin_cert = false or no public ingress. Consumed by the app-gcp stack's mattermost-origin-tls-cert secret."
  value       = one([for c in component.cloudflare : c.origin_certificate_pem])
}

output "origin_private_key_pem" {
  type        = string
  description = "Private key (PEM) for the Origin CA certificate. Null when manage_origin_cert = false or no public ingress. Consumed by the app-gcp stack's mattermost-origin-tls-key secret."
  value       = one([for c in component.cloudflare : c.origin_private_key_pem])
  sensitive   = true
}
