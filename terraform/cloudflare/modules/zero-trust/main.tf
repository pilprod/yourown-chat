# Zero Trust access to private in-cluster services: client -> Access policy
# (allowed emails) -> Cloudflare Tunnel (outbound-only cloudflared pod) ->
# ClusterIP, no public exposure. Requires an ACCOUNT-scoped API token
# (Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit + MCP Portals:Edit).
# The sibling zero-trust-organization component additionally needs Access:
# Organizations, Identity Providers, and Groups:Edit.

# config_src = "cloudflare": ingress rules are pushed from here; the pod just
# runs `tunnel run`.
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id    = var.account_id
  name          = "yourown-chat-private"
  tunnel_secret = random_id.tunnel_secret.b64_std
  config_src    = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

# hostname -> in-cluster service URL; a catch-all 404 closes everything else.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = concat(
      [for label, service in var.upstreams : {
        hostname = "${label}.${var.domain}"
        service  = service
      }],
      [{ service = "http_status:404" }]
    )
  }
}

# Proxied DNS onto the tunnel (no origin IP; points at cfargotunnel.com).
resource "cloudflare_dns_record" "this" {
  for_each = var.upstreams

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Private service behind Cloudflare Tunnel + Access (Managed by Terraform)."
}

moved {
  from = cloudflare_record.this
  to   = cloudflare_dns_record.this
}

locals {
  mcp_upstreams = {
    for label, service in var.upstreams : label => service
    if startswith(label, "mcp-")
  }

  managed_oauth_allowed_uris = [
    "https://claude.ai/api/mcp/auth_callback",
    "https://chatgpt.com/*",
    "https://playground.ai.cloudflare.com/*",
    "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
  ]
}

# Access application + inline allow-list policy per hostname. Provider v5 no
# longer manages application-scoped policies as standalone resources.
resource "cloudflare_zero_trust_access_application" "this" {
  for_each = var.upstreams

  account_id       = var.account_id
  name             = each.key
  domain           = "${each.key}.${var.domain}"
  type             = "self_hosted"
  session_duration = var.session_duration

  oauth_configuration = startswith(each.key, "mcp-") ? {
    enabled = true
    dynamic_client_registration = {
      enabled                = true
      allow_any_on_localhost = true
      allow_any_on_loopback  = true
      allowed_uris           = local.managed_oauth_allowed_uris
    }
    grant = {
      access_token_lifetime = "15m"
      session_duration      = "336h"
    }
  } : null

  policies = [{
    name       = "allowed-emails"
    precedence = 1
    decision   = "allow"
    include    = [for email in var.allowed_emails : { email = { email = email } }]
  }]
}

removed {
  from = cloudflare_zero_trust_access_policy.allow

  lifecycle {
    destroy = false
  }
}

# AI Controls catalog entry for every public MCP origin. OAuth is Cloudflare
# Access Managed OAuth on the self-hosted application above. The shared
# callback avoids a portal-specific redirect URI.
resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "this" {
  for_each = local.mcp_upstreams

  account_id                       = var.account_id
  id                               = trimprefix(each.key, "mcp-")
  name                             = each.key
  description                      = "yourown-chat ${each.key} MCP server"
  hostname                         = "https://${each.key}.${var.domain}/mcp"
  auth_type                        = "oauth"
  is_shared_oauth_callback_enabled = true
  secure_web_gateway               = false
}

# A dedicated type=mcp Access application controls which authenticated users
# can discover each server through a portal. It is separate from the
# self_hosted application that protects the server's direct URL.
resource "cloudflare_zero_trust_access_application" "mcp_server" {
  for_each = local.mcp_upstreams

  account_id = var.account_id
  name       = "${each.key}-portal-policy"
  type       = "mcp"
  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.this[each.key].id
  }]

  policies = [{
    name       = "allowed-emails"
    precedence = 1
    decision   = "allow"
    include    = [for email in var.allowed_emails : { email = { email = email } }]
  }]
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_portal" "this" {
  account_id         = var.account_id
  id                 = "yourown-chat"
  name               = "yourown-chat"
  description        = "Curated MCP access for yourown-chat agents"
  hostname           = "mcp.${var.domain}"
  allow_code_mode    = true
  secure_web_gateway = false

  servers = [for server in cloudflare_zero_trust_access_ai_controls_mcp_server.this : {
    server_id        = server.id
    default_disabled = false
    on_behalf        = true
  }]
}

# Cloudflare creates the Portal's type=mcp_portal Access application as a side
# effect. The read is deliberately deferred until the Portal exists; its
# computed UUID becomes the dependency token that makes Terraform Stacks defer
# the separate import/management component to a convergence plan.
data "cloudflare_zero_trust_access_applications" "mcp_portal" {
  account_id = var.account_id
  domain     = cloudflare_zero_trust_access_ai_controls_mcp_portal.this.hostname
  exact      = true

  depends_on = [cloudflare_zero_trust_access_ai_controls_mcp_portal.this]

  lifecycle {
    postcondition {
      condition = length([
        for application in self.result : application
        if application.type == "mcp_portal"
      ]) == 1
      error_message = "Expected exactly one type=mcp_portal Access application for ${cloudflare_zero_trust_access_ai_controls_mcp_portal.this.hostname} after creating the Portal."
    }
  }
}

# The Portal API does not create DNS when called by Terraform.
resource "cloudflare_dns_record" "mcp_portal" {
  zone_id = var.zone_id
  name    = "mcp"
  type    = "CNAME"
  content = "gateway.agents.cloudflare.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare MCP Portal (Managed by Terraform)."
}
