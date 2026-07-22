# ---------------------------------------------------------------------------
# Zero Trust access to PRIVATE in-cluster services, without any public
# exposure of the services themselves:
#
#   client -> Cloudflare edge (Access policy: allowed emails) -> Cloudflare
#   Tunnel (outbound-only cloudflared pod in the cluster) -> ClusterIP.
#
# Two consumer kinds share the one tunnel:
#   * MCP servers (mcp-terraform, mcp-google-cloud) for personal MCP clients
#     (Claude) -- fronted additionally by the MCP Server Portal (beta,
#     dashboard-only, layered on manually: it speaks the MCP OAuth flow);
#   * ordinary BROWSER apps (dev Mattermost) -- plain Access login in the
#     browser, the mature non-beta path, replacing a would-be tailscale
#     operator for developer access.
#
# The services keep no auth of their own (they trust the network perimeter);
# this module moves that perimeter to the Cloudflare edge: every request must
# pass an Access policy BEFORE it can reach the tunnel.
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

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.account_id
  name       = "yourown-chat-private"
  secret     = random_id.tunnel_secret.b64_std
  config_src = "cloudflare"
}

# hostname -> in-cluster service URL, one public hostname per MCP server.
# A catch-all 404 closes anything that is not an explicit upstream.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

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
resource "cloudflare_record" "this" {
  for_each = var.upstreams

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Private service behind Cloudflare Tunnel + Access (Managed by Terraform)."
}

# Access application + allow-list policy per hostname: only the listed emails
# (via the configured IdP / one-time PIN) pass the edge. Everyone else is
# stopped before the request ever reaches the tunnel.
resource "cloudflare_zero_trust_access_application" "this" {
  for_each = var.upstreams

  account_id       = var.account_id
  name             = each.key
  domain           = "${each.key}.${var.domain}"
  type             = "self_hosted"
  session_duration = var.session_duration
}

resource "cloudflare_zero_trust_access_policy" "allow" {
  for_each = var.upstreams

  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.this[each.key].id
  name           = "allowed-emails"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.allowed_emails
  }
}
