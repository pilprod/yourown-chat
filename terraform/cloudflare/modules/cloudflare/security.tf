# ---------------------------------------------------------------------------
# WAF / rules, expressed as Cloudflare Rulesets.
#   * custom_firewall — WAF custom rules. Available on Free (limited count).
#     Created only when at least one rule is supplied.
#   * managed_waf      — Cloudflare Managed Ruleset. PAID (Pro+); off by default.
#   * rate_limit       — rate limiting rules. PAID/advanced; off by default
#     (created only when at least one rule is supplied).
# ---------------------------------------------------------------------------

resource "cloudflare_ruleset" "custom_firewall" {
  count = length(var.custom_firewall_rules) > 0 ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "custom-firewall"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [for rule in var.custom_firewall_rules : {
    action      = rule.action
    expression  = rule.expression
    description = rule.description
    enabled     = rule.enabled
  }]
}

resource "cloudflare_ruleset" "managed_waf" {
  count = var.managed_waf_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "managed-waf"
  kind    = "zone"
  phase   = "http_request_firewall_managed"

  rules = [
    {
      action      = "execute"
      description = "Deploy the Cloudflare Managed Ruleset"
      expression  = "true"
      enabled     = true
      action_parameters = {
        id = "efb7b8c949ac4650a09736fc376e9aee" # Cloudflare Managed Ruleset
      }
    }
  ]
}

resource "cloudflare_ruleset" "rate_limit" {
  count = length(var.rate_limit_rules) > 0 ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "rate-limiting"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [for rule in var.rate_limit_rules : {
    action      = rule.action
    expression  = rule.expression
    description = rule.description
    enabled     = true
    ratelimit = {
      characteristics     = rule.characteristics
      period              = rule.period
      requests_per_period = rule.requests_per_period
      mitigation_timeout  = rule.mitigation_timeout
    }
  }]
}
