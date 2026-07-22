# CLOUDFLARE stack: the public edge plus its origin-protection / tunnel secrets.
# The only place the Cloudflare API token is exercised. Linked to platform-gcp
# (ingress IP, CMEK, WI member). Secrets are written to Secret Manager HERE
# because linked stacks cannot publish sensitive values across a boundary.

locals {
  common_labels = {
    managed-by = "terraform"
    stack      = "yourown-chat-cloudflare"
  }
}

# The whole zone: DNS, edge TLS/security, DNSSEC, WAF, origin TLS + AOP. Gated
# on public_ingress_enabled so private deployments skip Cloudflare entirely.
component "cloudflare" {
  for_each = var.public_ingress_enabled ? toset(["default"]) : toset([])

  source = "./modules/cloudflare"

  inputs = {
    domain        = var.domain
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
  }

  providers = {
    cloudflare = provider.cloudflare.this
    tls        = provider.tls.this
  }
}

# Origin CA cert/key + the AOP verification CA, written to Secret Manager
# (CMEK-encrypted, readable only by the mattermost workload) for ingress-nginx.
component "origin_secrets" {
  for_each = var.public_ingress_enabled ? toset(["default"]) : toset([])

  source = "./modules/secrets"

  inputs = {
    project_id        = var.project_id
    replica_locations = [var.region]
    labels            = local.common_labels
    kms_key_name      = var.cmek_key_id

    secrets = {
      "mattermost-origin-tls-cert" = {
        value     = one([for c in component.cloudflare : c.origin_certificate_pem])
        accessors = [var.workload_identity_members.mattermost]
      }
      "mattermost-origin-tls-key" = {
        value     = one([for c in component.cloudflare : c.origin_private_key_pem])
        accessors = [var.workload_identity_members.mattermost]
      }
      # Populated whenever the edge exists so the origin's auth-tls-secret always
      # resolves (a missing CA 403s nginx); enforcement is gated by aop_enabled.
      "cloudflare-origin-pull-ca" = {
        value     = one([for c in component.cloudflare : c.aop_origin_pull_ca_pem])
        accessors = [var.workload_identity_members.mattermost]
      }
    }
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# Zero Trust access to private services: Access allow-list -> Tunnel ->
# ClusterIP, for both personal MCP clients and dev Mattermost browser access.
# Requires an ACCOUNT-scoped API token; the flag is the kill switch for the
# beta claude.ai <-> MCP-portal interop (docs/MCP.md).
component "zero_trust" {
  for_each = var.zero_trust_enabled ? toset(["default"]) : toset([])

  source = "./modules/zero-trust"

  inputs = {
    # Derived from the zone lookup -- no hand-copied dashboard value.
    account_id     = one([for c in component.cloudflare : c.account_id])
    zone_id        = one([for c in component.cloudflare : c.zone_id])
    domain         = var.domain
    upstreams      = var.zero_trust_upstreams
    allowed_emails = var.zero_trust_allowed_emails
  }

  providers = {
    cloudflare = provider.cloudflare.this
    random     = provider.random.this
  }
}

# cloudflared run token -> Secret Manager (sensitive, cannot cross stacks);
# app-gcp reads it back into the in-cluster mcp-tunnel Secret.
component "zero_trust_secrets" {
  for_each = var.zero_trust_enabled ? toset(["default"]) : toset([])

  source = "./modules/secrets"

  inputs = {
    project_id        = var.project_id
    replica_locations = [var.region]
    labels            = local.common_labels
    kms_key_name      = var.cmek_key_id

    secrets = {
      "mcp-tunnel-token" = {
        value = one([for m in component.zero_trust : m.tunnel_token])
      }
    }
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}
