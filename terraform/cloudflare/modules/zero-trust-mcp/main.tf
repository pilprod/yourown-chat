# ---------------------------------------------------------------------------
# Zero Trust access to in-cluster MCP servers, without ANY public exposure of
# the servers themselves:
#
#   personal MCP client (Claude) -> Cloudflare edge (Access policy: allowed
#   emails) -> Cloudflare Tunnel (outbound-only cloudflared pod in the
#   cluster) -> in-cluster MCP Service.
#
# The servers keep no auth of their own (they trust the network perimeter);
# this module moves that perimeter to the Cloudflare edge: every request must
# pass an Access policy BEFORE it can reach the tunnel. The MCP Server Portal
# (the piece that speaks the MCP OAuth flow to clients like Claude) is beta
# and dashboard-only -- it is layered on manually, see docs/MCP.md.
#
# EVERYTHING here needs an ACCOUNT-scoped API token (Cloudflare Tunnel:Edit +
# Access: Apps and Policies:Edit on the account, plus the existing zone
# permissions) -- the default zone-scoped token cannot manage Zero Trust.
# ---------------------------------------------------------------------------

# Tunnel credential: cloudflared authenticates with a token derived from this
# secret. Remotely managed (config_src = "cloudflare"): the ingress rules below
# are pushed from here, the pod just runs `tunnel run`.
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "mcp" {
  account_id = var.account_id
  name       = "mcp-servers"
  secret     = random_id.tunnel_secret.b64_std
  config_src = "cloudflare"
}

# hostname -> in-cluster service URL, one public hostname per MCP server.
# A catch-all 404 closes anything that is not an explicit upstream.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "mcp" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.mcp.id

  config {
    dynamic "ingress_rule" {
      for_each = var.upstreams
      content {
        hostname = "${ingress_rule.key}.${var.domain}"
        service  = ingress_rule.value
      }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# Proxied DNS onto the tunnel. No origin IP involved: the record points at the
# tunnel's internal cfargotunnel.com target.
resource "cloudflare_record" "mcp" {
  for_each = var.upstreams

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.mcp.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "MCP server behind Cloudflare Tunnel + Access (Managed by Terraform)."
}

# Access application + allow-list policy per hostname: only the listed emails
# (via the configured IdP / one-time PIN) pass the edge. Everyone else is
# stopped before the request ever reaches the tunnel.
resource "cloudflare_zero_trust_access_application" "mcp" {
  for_each = var.upstreams

  account_id       = var.account_id
  name             = "mcp-${each.key}"
  domain           = "${each.key}.${var.domain}"
  type             = "self_hosted"
  session_duration = var.session_duration
}

resource "cloudflare_zero_trust_access_policy" "allow" {
  for_each = var.upstreams

  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.mcp[each.key].id
  name           = "allowed-emails"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.allowed_emails
  }
}
