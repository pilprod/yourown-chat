# ---------------------------------------------------------------------------
# Origin TLS hardening (both optional, default OFF).
#
#   * Origin CA certificate — issue a Cloudflare Origin CA cert (served by the
#     GKE ingress) straight from Terraform. Needs the provider configured with an
#     Origin CA key / a token carrying Origin CA edit; the PEM + key are exposed
#     as (sensitive) outputs to load into the origin secret. Off by default.
#
#   * Authenticated Origin Pulls (per-hostname mTLS) — make the edge present a
#     client cert to the origin so only our Cloudflare zone can reach it. Off by
#     default; supply the client cert/key material to enable.
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

resource "cloudflare_authenticated_origin_pulls_certificate" "aop" {
  count = var.aop_enabled ? 1 : 0

  zone_id     = data.cloudflare_zone.this.id
  certificate = var.aop_certificate
  private_key = var.aop_private_key
  type        = "per-hostname"
}

resource "cloudflare_authenticated_origin_pulls" "aop" {
  count = var.aop_enabled ? 1 : 0

  zone_id                                = data.cloudflare_zone.this.id
  hostname                               = local.apex_record_name
  authenticated_origin_pulls_certificate = cloudflare_authenticated_origin_pulls_certificate.aop[0].id
  enabled                                = true
}
