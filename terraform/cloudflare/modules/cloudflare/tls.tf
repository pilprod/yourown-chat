# ---------------------------------------------------------------------------
# Origin TLS hardening.
#
#   * Origin CA certificate (ON by default) — issue a Cloudflare Origin CA cert
#     (served by the GKE ingress) straight from Terraform, so Full (Strict) TLS
#     has a matching origin cert. Needs the token to carry SSL and Certificates:
#     Edit; the PEM + key are exposed as (sensitive) outputs to load into the
#     platform mattermost-origin-tls-cert / -key secrets.
#
#   * Authenticated Origin Pulls (per-hostname mTLS, enforcement OFF by default)
#     — make the edge present a client cert to the origin so only our Cloudflare
#     zone can reach it. The client cert is SELF-GENERATED here (self-signed,
#     client_auth): we own both ends, so the same PEM is Cloudflare's client cert
#     AND the origin's verification CA. It is generated whenever the edge exists
#     (not only when aop_enabled) so the cloudflare-origin-pull-ca Secret is
#     always populated -- ingress-nginx loads auth-tls-secret regardless of
#     verify-client, and a missing CA there fails annotation parsing (HTTP 403).
#     Enforcement is gated by aop_enabled (edge presents the cert + origin
#     verify-client on); when off the CA is loaded but inert.
# ---------------------------------------------------------------------------

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

# Self-signed client keypair for AOP. Generated UNCONDITIONALLY (whenever this
# module exists, i.e. public_ingress_enabled) so the origin's verification CA is
# always available; enforcement is toggled separately by aop_enabled. The private
# key is uploaded to Cloudflare (below) and kept in state; only the certificate
# (public) is exported for the origin's cloudflare-origin-pull-ca Secret.
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
