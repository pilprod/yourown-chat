# ---------------------------------------------------------------------------
# CLOUDFLARE stack: the public edge for yourown.chat, isolated in its own
# stack. It is the only place the Cloudflare API token is ever exercised, so
# the third-party edge shares no state (and no blast radius) with either GCP
# stack.
#
# LINKED both ways along the chain platform-gcp -> cloudflare -> app-gcp:
#   - consumes upstream_input.platform.ingress_ip_address (the reserved static
#     IP the platform-gcp stack allocates) for the proxied apex A record;
#   - publishes the Origin CA cert/key, which the app-gcp stack pours into the
#     mattermost-origin-tls-* Secret Manager containers.
# ---------------------------------------------------------------------------

# --- Cloudflare edge (public ingress only) ----------------------------------
# Drives the whole zone: DNS (proxied apex A wired to the platform ingress IP
# via upstream_input), www, extra records, CAA, edge TLS/security settings,
# DNSSEC, WAF rules and optional origin TLS (Origin CA cert + Authenticated
# Origin Pulls). Gated on public_ingress_enabled so dev/private deployments
# skip Cloudflare entirely.
component "cloudflare" {
  for_each = var.public_ingress_enabled ? toset(["default"]) : toset([])

  source = "./modules/cloudflare"

  inputs = {
    domain = var.domain
    # The reserved static IP the PLATFORM-GCP stack allocates is the address
    # the proxied apex A record points at. It arrives as a last-applied
    # upstream value, so DNS can only ever point at an IP that already exists.
    origin_ip     = var.ingress_ip_address
    proxied       = var.cloudflare_proxied
    manage_www    = var.cloudflare_manage_www
    extra_records = var.cloudflare_extra_records
    caa_records   = var.cloudflare_caa_records

    ssl_mode         = var.cloudflare_ssl_mode
    always_use_https = var.cloudflare_always_use_https
    min_tls_version  = var.cloudflare_min_tls_version
    hsts             = var.cloudflare_hsts
    dnssec_enabled   = var.cloudflare_dnssec_enabled

    custom_firewall_rules = var.cloudflare_custom_firewall_rules
    managed_waf_enabled   = var.cloudflare_managed_waf_enabled
    rate_limit_rules      = var.cloudflare_rate_limit_rules

    manage_origin_cert = var.cloudflare_manage_origin_cert
    aop_enabled        = var.cloudflare_aop_enabled
    aop_certificate    = var.cloudflare_aop_certificate
    aop_private_key    = var.cloudflare_aop_private_key
  }

  providers = {
    cloudflare = provider.cloudflare.this
    tls        = provider.tls.this
  }
}
