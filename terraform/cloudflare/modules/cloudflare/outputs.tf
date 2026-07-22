output "zone_id" {
  description = "Cloudflare zone ID resolved from the domain."
  value       = data.cloudflare_zone.this.id
}

output "account_id" {
  description = "Cloudflare account ID owning the zone. Feeds the zero-trust module (tunnels and Access apps are account-level), so no hand-copied account ID input is needed."
  value       = data.cloudflare_zone.this.account_id
}

output "record_hostname" {
  description = "Fully-qualified hostname of the managed apex A record."
  value       = cloudflare_record.apex.hostname
}

output "record_id" {
  description = "ID of the managed apex A record."
  value       = cloudflare_record.apex.id
}

output "origin_ip" {
  description = "IPv4 the proxied apex A record points at (echoes the platform ingress IP)."
  value       = cloudflare_record.apex.content
}

output "dnssec" {
  description = "DNSSEC DS record material to publish at the registrar (null when dnssec_enabled = false)."
  value = var.dnssec_enabled ? {
    status      = cloudflare_zone_dnssec.this[0].status
    ds          = cloudflare_zone_dnssec.this[0].ds
    digest      = cloudflare_zone_dnssec.this[0].digest
    key_tag     = cloudflare_zone_dnssec.this[0].key_tag
    algorithm   = cloudflare_zone_dnssec.this[0].algorithm
    digest_type = cloudflare_zone_dnssec.this[0].digest_type
  } : null
}

output "origin_certificate_pem" {
  description = "Cloudflare Origin CA certificate PEM to serve from the GKE ingress (null when manage_origin_cert = false)."
  value       = var.manage_origin_cert ? cloudflare_origin_ca_certificate.origin[0].certificate : null
}

output "origin_private_key_pem" {
  description = "Private key for the Origin CA certificate (null when manage_origin_cert = false). Load into the origin TLS secret."
  value       = var.manage_origin_cert ? tls_private_key.origin[0].private_key_pem : null
  sensitive   = true
}

output "aop_origin_pull_ca_pem" {
  description = "Self-signed AOP client certificate (PEM). Written to the cloudflare-origin-pull-ca Secret as the CA ingress-nginx verifies Cloudflare's authenticated origin pulls against. Always present so the CA Secret is populated even when AOP enforcement is off. Not sensitive (public certificate; the private key stays in state and is uploaded to Cloudflare)."
  value       = tls_self_signed_cert.aop.cert_pem
}
