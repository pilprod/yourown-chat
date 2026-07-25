# Provider v5 manages each zone setting through a separate API resource.
locals {
  string_zone_settings = {
    ssl                      = var.ssl_mode
    always_use_https         = var.always_use_https
    min_tls_version          = var.min_tls_version
    tls_1_3                  = var.tls_1_3
    automatic_https_rewrites = var.automatic_https_rewrites
    opportunistic_encryption = var.opportunistic_encryption
    http3                    = var.http3
    "0rtt"                   = var.zero_rtt
    brotli                   = var.brotli
    websockets               = var.websockets
    ipv6                     = var.ipv6
    security_level           = var.security_level
    browser_check            = var.browser_check
    email_obfuscation        = var.email_obfuscation
  }
}

resource "cloudflare_zone_setting" "string" {
  for_each = local.string_zone_settings

  zone_id    = data.cloudflare_zone.this.id
  setting_id = each.key
  value      = each.value
}

resource "cloudflare_zone_setting" "challenge_ttl" {
  zone_id    = data.cloudflare_zone.this.id
  setting_id = "challenge_ttl"
  value      = var.challenge_ttl
}

resource "cloudflare_zone_setting" "security_header" {
  zone_id    = data.cloudflare_zone.this.id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
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

  lifecycle {
    # Provider v5 declares status as Optional(active|disabled), but the API
    # legitimately returns pending until the registrar publishes the DS record.
    # Ignoring that workflow status prevents pending -> null from producing an
    # update on every convergence plan. count still controls enable/disable.
    #
    # TODO(registrar-transfer): yourown.chat is transferring from GoDaddy to
    # Cloudflare Registrar. Do not add the DS record manually at GoDaddy.
    # Cloudflare Registrar will publish it from CDS/CDNSKEY after the transfer.
    # Once the API reports active, replace this ignore with status = "active".
    ignore_changes = [status]
  }
}
