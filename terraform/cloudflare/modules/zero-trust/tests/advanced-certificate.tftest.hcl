mock_provider "cloudflare" {}
mock_provider "random" {}

variables {
  account_id = "00000000000000000000000000000000"
  zone_id    = "11111111111111111111111111111111"
  domain     = "yourown.chat"
  upstreams = {
    "dev.kagent" = "http://kagent-ui.kagent-dev.svc.cluster.local:8080"
    kagent       = "http://kagent-ui.kagent-system.svc.cluster.local:8080"
  }
  allowed_emails = ["operator@example.com"]
}

run "advanced_pack_is_disabled_by_default" {
  command = plan

  assert {
    condition     = length(cloudflare_certificate_pack.deep_upstreams) == 0
    error_message = "The paid Advanced certificate pack must remain absent until explicitly enabled."
  }
}

run "opt_in_preserves_exact_deep_hostname_set" {
  command = plan

  variables {
    advanced_certificate_manager_enabled = true
  }

  assert {
    condition     = length(cloudflare_certificate_pack.deep_upstreams) == 1
    error_message = "Explicit opt-in must create exactly one Advanced certificate pack."
  }

  assert {
    condition = cloudflare_certificate_pack.deep_upstreams["default"].hosts == toset([
      "yourown.chat",
      "*.yourown.chat",
      "dev.kagent.yourown.chat",
    ])
    error_message = "The Advanced certificate pack must preserve the apex, first-level wildcard and exact kagent development hostname."
  }
}
