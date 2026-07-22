# ---------------------------------------------------------------------------
# CLOUDFLARE stack: the public edge for yourown.chat plus its origin-protection
# secrets, isolated in their own stack. It is the only place the Cloudflare API
# token is ever exercised.
#
# LINKED to platform-gcp (upstream_input "platform" in cloudflare.tfdeploy.hcl):
#   - consumes the reserved static ingress IP for the proxied apex A record;
#   - consumes the CMEK key + the mattermost Workload Identity member for the
#     origin-TLS Secret Manager containers.
#
# The origin_secrets component lives HERE (not in app-gcp) because linked
# stacks cannot publish SENSITIVE values: the Origin CA private key therefore
# never crosses a stack boundary -- this stack issues the cert AND writes the
# cert/key into Secret Manager itself.
# ---------------------------------------------------------------------------

locals {
  common_labels = {
    managed-by = "terraform"
    stack      = "yourown-chat-cloudflare"
  }
}

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
  }

  providers = {
    cloudflare = provider.cloudflare.this
    tls        = provider.tls.this
  }
}

# --- Origin-protection secrets (Secret Manager) ------------------------------
# The Origin CA cert/key flow straight from the cloudflare component into these
# containers, so ingress-nginx can serve Full (Strict) TLS with zero manual
# steps. When manage_origin_cert = false the values are null and the module
# creates empty containers to be filled out-of-band. The AOP CA stays an empty
# container (Cloudflare-supplied, not issued here). Only the mattermost
# workload (platform-published IAM member) may read them; replicas are
# CMEK-encrypted with the platform's shared key.
component "origin_secrets" {
  for_each = var.public_ingress_enabled ? toset(["default"]) : toset([])

  source = "./modules/secrets"

  inputs = {
    project_id        = var.project_id
    replica_locations = [var.region]
    labels            = local.common_labels

    # CMEK: the platform's shared key (null when it runs cmek_enabled = false).
    kms_key_name = var.cmek_key_id

    secrets = {
      "mattermost-origin-tls-cert" = {
        value     = one([for c in component.cloudflare : c.origin_certificate_pem])
        accessors = [var.workload_identity_members.mattermost]
      }
      "mattermost-origin-tls-key" = {
        value     = one([for c in component.cloudflare : c.origin_private_key_pem])
        accessors = [var.workload_identity_members.mattermost]
      }
      "cloudflare-origin-pull-ca" = {
        # The self-signed AOP client certificate (public) that ingress-nginx
        # verifies Cloudflare's authenticated origin pulls against. Populated
        # whenever the edge exists so the origin's auth-tls-secret always
        # resolves (a missing CA there fails nginx annotation parsing -> 403);
        # enforcement is toggled separately by aop_enabled.
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

# --- Zero Trust access to private in-cluster services (FLAGGED, default off) -
# Client -> Access policy (allowed emails) -> Cloudflare Tunnel -> ClusterIP.
# One tunnel serves both consumer kinds: personal MCP clients (Claude) reaching
# the internal MCP servers, and BROWSERS reaching dev Mattermost (plain Access
# login, replacing a would-be tailscale operator). The services get zero public
# exposure; the perimeter moves to the Cloudflare edge. OFF by default:
# enabling requires an ACCOUNT-scoped API token (Cloudflare Tunnel:Edit +
# Access:Edit) and the claude.ai <-> MCP-portal interop is still beta -- see
# docs/MCP.md for the smoke test this gate exists for (the dev Mattermost
# browser path has no beta dependency).
component "zero_trust" {
  for_each = var.zero_trust_enabled ? toset(["default"]) : toset([])

  source = "./modules/zero-trust"

  inputs = {
    # Account ID is DERIVED from the zone lookup (the zone knows its owning
    # account) -- no hand-copied dashboard value.
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

# The cloudflared run token, written straight into Secret Manager HERE (same
# rationale as origin_secrets: sensitive values cannot cross a stack boundary).
# app-gcp reads it back and creates the in-cluster mcp-tunnel Secret.
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
