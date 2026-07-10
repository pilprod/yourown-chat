# Stack outputs — expose only what downstream consumers (operators, docs,
# future Infragraph) actually need.

output "zone_id" {
  type        = string
  description = "Cloudflare zone ID for the managed domain."
  value       = component.zone.zone_id
}

output "record_hostname" {
  type        = string
  description = "Fully-qualified hostname of the proxied apex A record."
  value       = component.zone.record_hostname
}

output "origin_ip" {
  type        = string
  description = "IPv4 the proxied apex A record points at (echoes the platform ingress IP)."
  value       = component.zone.origin_ip
}

output "dnssec" {
  type        = any
  description = "DNSSEC DS material to publish at the registrar (null when dnssec_enabled = false)."
  value       = component.zone.dnssec
}

output "origin_certificate_pem" {
  type        = string
  description = "Cloudflare Origin CA certificate PEM (null when manage_origin_cert = false)."
  value       = component.zone.origin_certificate_pem
}

output "origin_private_key_pem" {
  type        = string
  description = "Private key for the Origin CA certificate (null when manage_origin_cert = false)."
  value       = component.zone.origin_private_key_pem
  sensitive   = true
}
