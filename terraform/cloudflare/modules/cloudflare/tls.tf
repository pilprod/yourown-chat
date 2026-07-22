# Origin TLS hardening: the Cloudflare Origin CA cert (served by the ingress for
# Full (Strict) TLS) and the AOP client cert (below).

resource "tls_private_key" "origin" {
  count = var.manage_origin_cert ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  count = var.manage_origin_cert ? 1 : 0

  private_key_pem = tls_private_key.origin[0].private_key_pem

  subject {
    common_name = var.domain
  }

  dns_names = distinct(concat([var.domain, "*.${var.domain}"], var.origin_cert_hostnames))
}

resource "cloudflare_origin_ca_certificate" "origin" {
  count = var.manage_origin_cert ? 1 : 0

  csr                = tls_cert_request.origin[0].cert_request_pem
  hostnames          = distinct(concat([var.domain, "*.${var.domain}"], var.origin_cert_hostnames))
  request_type       = "origin-rsa"
  requested_validity = var.origin_cert_validity_days
}

# Self-signed AOP client keypair. Generated unconditionally so the origin's
# verification CA is always populated (a missing one 403s nginx); enforcement is
# gated separately by aop_enabled. Same self-signed PEM serves as both the edge
# client cert and the origin CA (we own both ends).
resource "tls_private_key" "aop" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "aop" {
  private_key_pem = tls_private_key.aop.private_key_pem

  subject {
    common_name  = "aop.${var.domain}"
    organization = "yourown-chat Authenticated Origin Pulls"
  }

  # Long-lived on purpose: this is an internal Cloudflare<->origin trust anchor,
  # not a public cert. Rotate deliberately (taint) rather than on a short clock.
  validity_period_hours = 87600 # 10 years
  early_renewal_hours   = 720   # regenerate 30 days before expiry

  # Presented by the edge as a TLS client certificate; verified directly by the
  # origin (self-signed leaf trusted at depth 0, matching auth-tls-verify-depth 1).
  allowed_uses = ["digital_signature", "key_encipherment", "client_auth"]
}

resource "cloudflare_authenticated_origin_pulls_certificate" "aop" {
  count = var.aop_enabled ? 1 : 0

  zone_id     = data.cloudflare_zone.this.id
  certificate = tls_self_signed_cert.aop.cert_pem
  private_key = tls_private_key.aop.private_key_pem
  type        = "per-hostname"
}

resource "cloudflare_authenticated_origin_pulls" "aop" {
  count = var.aop_enabled ? 1 : 0

  zone_id                                = data.cloudflare_zone.this.id
  hostname                               = local.apex_record_name
  authenticated_origin_pulls_certificate = cloudflare_authenticated_origin_pulls_certificate.aop[0].id
  enabled                                = true
}
