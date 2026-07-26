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
      "15m"
    )
    error_message = "Keep access tokens short-lived; the shared fix must preserve automatic refresh."
  }
}
