locals {
  managed_oauth_allowed_uris = [
    "https://claude.ai/api/mcp/auth_callback",
    "https://chatgpt.com/*",
    "https://playground.ai.cloudflare.com/*",
    "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
  ]
}

resource "cloudflare_zero_trust_access_application" "this" {
  account_id       = var.account_id
  name             = "yourown-chat"
  domain           = var.hostname
  type             = "mcp_portal"
  session_duration = "24h"

  oauth_configuration = {
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
  }

  policies = [{
    name       = "allowed-emails"
    precedence = 1
    decision   = "allow"
    include    = [for email in var.allowed_emails : { email = { email = email } }]
  }]

  lifecycle {
    prevent_destroy = true
  }
}
