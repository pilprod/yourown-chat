locals {
  # Temporary compatibility window for long-running agent sessions. Codex
  # currently loses the rotated refresh token and fails with invalid_grant at
  # the normal 15-minute boundary. Restore this to 15m after the client refresh
  # lifecycle is fixed and verified end-to-end.
  managed_oauth_access_token_lifetime = "24h"
  managed_oauth_session_duration      = "336h"

  managed_oauth_allowed_uris = [
    "https://claude.ai/api/mcp/auth_callback",
    "https://chatgpt.com/*",
    "https://yourown.chat/plugins/mattermost-ai/oauth/callback",
    "https://dev.yourown.chat/plugins/mattermost-ai/oauth/callback",
    "https://playground.ai.cloudflare.com/*",
    "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
  ]
}

resource "cloudflare_zero_trust_access_application" "this" {
  account_id = var.account_id
  name       = "yourown-chat"
  domain     = var.hostname
  type       = "mcp_portal"
  # Keep the Access and grant expirations identical so a refresh never depends
  # on an earlier application-session expiry.
  session_duration = local.managed_oauth_session_duration

  oauth_configuration = {
    enabled = true
    dynamic_client_registration = {
      enabled                = true
      allow_any_on_localhost = true
      allow_any_on_loopback  = true
      allowed_uris           = local.managed_oauth_allowed_uris
    }
    grant = {
      access_token_lifetime = local.managed_oauth_access_token_lifetime
      session_duration      = local.managed_oauth_session_duration
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
