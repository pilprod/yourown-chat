# Cloudflare creates one type=mcp_portal Access application as a side effect of
# the MCP Portal API call. This module is a separate Stack component that is
# planned only after the Portal component has been applied, so the generated
# application can be discovered and imported with an ID known during plan.
data "cloudflare_zero_trust_access_applications" "portal" {
  account_id = var.account_id
  domain     = var.hostname
  exact      = true
}

locals {
  portal_applications = [
    for application in data.cloudflare_zero_trust_access_applications.portal.result : application
    if application.type == "mcp_portal"
  ]

  portal_application = one(local.portal_applications)

  managed_oauth_allowed_uris = [
    "https://claude.ai/api/mcp/auth_callback",
    "https://chatgpt.com/*",
    "https://playground.ai.cloudflare.com/*",
    "https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback",
  ]
}

import {
  to = cloudflare_zero_trust_access_application.this
  id = "accounts/${var.account_id}/${local.portal_application.id}"
}

resource "cloudflare_zero_trust_access_application" "this" {
  account_id       = var.account_id
  name             = "yourown-chat"
  domain           = var.hostname
  type             = "mcp_portal"
  session_duration = var.session_duration

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

    precondition {
      condition     = length(local.portal_applications) == 1
      error_message = "Expected exactly one type=mcp_portal Access application for ${var.hostname}; Cloudflare returned ${length(local.portal_applications)}."
    }
  }
}
