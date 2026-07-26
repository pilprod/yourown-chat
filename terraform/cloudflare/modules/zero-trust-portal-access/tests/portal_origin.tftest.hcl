mock_provider "cloudflare" {}

variables {
  account_id       = "00000000000000000000000000000000"
  hostname         = "mcp-origin.example.com"
  service_token_id = "00000000-0000-0000-0000-000000000000"
}

run "portal_origin_uses_only_worker_identity" {
  command = plan

  assert {
    condition = (
      cloudflare_zero_trust_access_application.this.oauth_configuration.enabled ==
      false
    )
    error_message = "Managed OAuth must stay disabled on the Portal origin."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_application.this.policies[0].decision ==
      "non_identity"
    )
    error_message = "The Portal origin must accept a machine identity, not end-user sessions."
  }

  assert {
    condition = (
      one(cloudflare_zero_trust_access_application.this.policies[0].include).service_token.token_id ==
      var.service_token_id
    )
    error_message = "The Portal origin policy must be bound to the OAuth Worker's service token."
  }
}
