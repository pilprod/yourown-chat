# ---------------------------------------------------------------------------
# Zone-wide edge settings (TLS + hardening) and DNSSEC. Every setting here is
# available on the Cloudflare Free plan.
# ---------------------------------------------------------------------------

resource "cloudflare_zone_settings_override" "this" {
  zone_id = data.cloudflare_zone.this.id

  settings {
    # --- TLS ---
    ssl                      = var.ssl_mode # strict = Full (Strict)
    always_use_https         = var.always_use_https
    min_tls_version          = var.min_tls_version
    tls_1_3                  = var.tls_1_3
    automatic_https_rewrites = var.automatic_https_rewrites
    opportunistic_encryption = var.opportunistic_encryption

    # --- Performance / protocol ---
    http3      = var.http3
    zero_rtt   = var.zero_rtt
    brotli     = var.brotli
    websockets = var.websockets
    ipv6       = var.ipv6

    # --- Hardening ---
    security_level    = var.security_level
    browser_check     = var.browser_check
    email_obfuscation = var.email_obfuscation
    challenge_ttl     = var.challenge_ttl

    # HSTS — force HTTPS at the browser once served over TLS.
    security_header {
      enabled            = var.hsts.enabled
      max_age            = var.hsts.max_age
      include_subdomains = var.hsts.include_subdomains
      preload            = var.hsts.preload
      nosniff            = var.hsts.nosniff
    }
  }
}

# DNSSEC — enabling here returns a DS record to publish at the registrar.
resource "cloudflare_zone_dnssec" "this" {
  count = var.dnssec_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
}
