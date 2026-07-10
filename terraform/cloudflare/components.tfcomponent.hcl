# ---------------------------------------------------------------------------
# Component wiring for the Cloudflare stack. A single component drives the whole
# zone: DNS (proxied apex A at the platform ingress IP, www, extra records,
# CAA), edge TLS/security settings, DNSSEC, WAF rules and optional origin TLS
# (Origin CA cert + Authenticated Origin Pulls).
#
# Graph:
#   zone  (Cloudflare zone lookup -> records + settings + rules + origin TLS)
#
# The ingress IP is a plain input (ingress_ip_address) copied from the platform
# stack output; the reserved IP is stable, so there is no live cross-stack
# coupling to break.
# ---------------------------------------------------------------------------

component "zone" {
  source = "./modules/zone"

  inputs = {
    domain        = var.domain
    origin_ip     = var.ingress_ip_address
    proxied       = var.proxied
    manage_www    = var.manage_www
    extra_records = var.extra_records
    caa_records   = var.caa_records

    ssl_mode         = var.ssl_mode
    always_use_https = var.always_use_https
    min_tls_version  = var.min_tls_version
    hsts             = var.hsts
    dnssec_enabled   = var.dnssec_enabled

    custom_firewall_rules = var.custom_firewall_rules
    managed_waf_enabled   = var.managed_waf_enabled
    rate_limit_rules      = var.rate_limit_rules

    manage_origin_cert = var.manage_origin_cert
    aop_enabled        = var.aop_enabled
    aop_certificate    = var.aop_certificate
    aop_private_key    = var.aop_private_key
  }

  providers = {
    cloudflare = provider.cloudflare.this
    tls        = provider.tls.this
  }
}
