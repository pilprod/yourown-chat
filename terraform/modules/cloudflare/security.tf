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

  dynamic "rules" {
    for_each = var.custom_firewall_rules
    content {
      action      = rules.value.action
      expression  = rules.value.expression
      description = rules.value.description
      enabled     = rules.value.enabled
    }
  }
}

resource "cloudflare_ruleset" "managed_waf" {
  count = var.managed_waf_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "managed-waf"
  kind    = "zone"
  phase   = "http_request_firewall_managed"

  rules {
    action      = "execute"
    description = "Deploy the Cloudflare Managed Ruleset"
    expression  = "true"
    enabled     = true
    action_parameters {
      id = "efb7b8c949ac4650a09736fc376e9aee" # Cloudflare Managed Ruleset
    }
  }
}

resource "cloudflare_ruleset" "rate_limit" {
  count = length(var.rate_limit_rules) > 0 ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "rate-limiting"
  kind    = "zone"
  phase   = "http_ratelimit"

  dynamic "rules" {
    for_each = var.rate_limit_rules
    content {
      action      = rules.value.action
      expression  = rules.value.expression
      description = rules.value.description
      enabled     = true

      ratelimit {
        characteristics     = rules.value.characteristics
        period              = rules.value.period
        requests_per_period = rules.value.requests_per_period
        mitigation_timeout  = rules.value.mitigation_timeout
      }
    }
  }
}
