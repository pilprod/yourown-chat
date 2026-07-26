resource "cloudflare_zero_trust_access_application" "this" {
  account_id       = var.account_id
  name             = "yourown-chat Portal origin"
  domain           = var.hostname
  type             = "mcp_portal"
  session_duration = "24h"

  # End-user OAuth terminates at the compatibility Worker on
  # mcp.yourown.chat. The Cloudflare Portal origin accepts only the Worker's
  # machine identity so Managed OAuth cannot rotate/revoke client grants.
  oauth_configuration = {
    enabled = false
  }

  policies = [{
    name       = "oauth-worker-service-token"
    precedence = 1
    decision   = "non_identity"
    include = [{
      service_token = {
        token_id = var.service_token_id
      }
    }]
  }]

  lifecycle {
    prevent_destroy = true
  }
}
