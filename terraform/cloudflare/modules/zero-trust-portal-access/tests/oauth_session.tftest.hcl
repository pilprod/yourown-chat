mock_provider "cloudflare" {}

variables {
  account_id     = "00000000000000000000000000000000"
  hostname       = "mcp.example.com"
  allowed_emails = ["operator@example.com"]
}

run "managed_oauth_session_covers_refresh_grant" {
  command = plan

  assert {
    condition = (
      cloudflare_zero_trust_access_application.this.session_duration ==
      cloudflare_zero_trust_access_application.this.oauth_configuration.grant.session_duration
    )
    error_message = "The Portal Access session must not expire before its Managed OAuth refresh grant."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_application.this.oauth_configuration.grant.access_token_lifetime ==
      "24h"
    )
    error_message = "Keep the temporary agent compatibility access-token lifetime pinned to 24 hours."
  }
}
