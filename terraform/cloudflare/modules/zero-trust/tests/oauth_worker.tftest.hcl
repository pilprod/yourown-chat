mock_provider "cloudflare" {}
mock_provider "random" {}

variables {
  account_id     = "00000000000000000000000000000000"
  zone_id        = "00000000000000000000000000000000"
  domain         = "example.com"
  team_name      = "example"
  allowed_emails = ["operator@example.com"]
  upstreams = {
    mcp-example = "http://mcp-example.mcp-example.svc.cluster.local:3000"
  }
}

run "oauth_worker_fronts_private_portal_origin" {
  command = plan

  assert {
    condition = (
      cloudflare_zero_trust_access_ai_controls_mcp_portal.this.hostname ==
      "mcp-origin.example.com"
    )
    error_message = "The AI Controls Portal must use the private origin hostname."
  }

  assert {
    condition = (
      cloudflare_workers_route.mcp_oauth.pattern ==
      "mcp.example.com/*"
    )
    error_message = "The OAuth Worker must intercept every path on the stable MCP hostname."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_application.mcp_oauth_identity.saas_app.grant_types ==
      tolist(["authorization_code_with_pkce"])
    )
    error_message = "Access for SaaS must authenticate the Worker through authorization code + PKCE."
  }

  assert {
    condition = contains(
      cloudflare_workers_script.mcp_oauth.compatibility_flags,
      "global_fetch_strictly_public",
    )
    error_message = "The Worker must traverse Cloudflare when fetching the same-zone Portal origin."
  }

  assert {
    condition = alltrue([
      for required in [
        "OAUTH_KV",
        "ACCESS_CLIENT_SECRET",
        "OAUTH_STATE_SECRET",
        "PORTAL_SERVICE_TOKEN_SECRET",
      ] :
      contains(
        [for binding in cloudflare_workers_script.mcp_oauth.bindings : binding.name],
        required,
      )
    ])
    error_message = "The Worker is missing an OAuth or Portal credential binding."
  }
}
