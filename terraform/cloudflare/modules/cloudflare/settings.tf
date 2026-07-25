# Phase 1 removed the aggregate v4 cloudflare_zone_settings_override from state
# without touching the remote zone. Provider v5 manages each setting through a
# separate API resource.
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

import {
  for_each = local.string_zone_settings

  to = cloudflare_zone_setting.string[each.key]
  id = "${data.cloudflare_zone.this.id}/${each.key}"
}

resource "cloudflare_zone_setting" "string" {
  for_each = local.string_zone_settings

  zone_id    = data.cloudflare_zone.this.id
  setting_id = each.key
  value      = each.value
}

import {
  to = cloudflare_zone_setting.challenge_ttl
  id = "${data.cloudflare_zone.this.id}/challenge_ttl"
}

resource "cloudflare_zone_setting" "challenge_ttl" {
  zone_id    = data.cloudflare_zone.this.id
  setting_id = "challenge_ttl"
  value      = var.challenge_ttl
}

import {
  to = cloudflare_zone_setting.security_header
  id = "${data.cloudflare_zone.this.id}/security_header"
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
}
