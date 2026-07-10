# ---------------------------------------------------------------------------
# Cloudflare zone — full Terraform-managed configuration for the public origin.
#
# This module owns everything about the zone that Terraform can drive
# deterministically on a Cloudflare Free plan, split across:
#   dns.tf       — DNS records (proxied apex A + www + extra records + CAA)
#   settings.tf  — zone TLS/security settings + DNSSEC
#   security.tf  — WAF custom rules (Free), managed WAF + rate limiting (paid,
#                  behind toggles), all as Cloudflare Rulesets
#   tls.tf       — optional Origin CA certificate + Authenticated Origin Pulls
#
# Free-plan features are on by default; paid features (managed WAF ruleset,
# rate limiting) are gated behind toggles that default off so a Free-plan apply
# never fails.
# ---------------------------------------------------------------------------

locals {
  # Proxied records must use TTL 1 ("automatic"); Cloudflare rejects any other
  # TTL while the orange cloud is on.
  apex_record_name = coalesce(var.record_name, var.domain)
  apex_ttl         = tobool(var.proxied) ? 1 : var.dns_ttl
}

data "cloudflare_zone" "this" {
  name = var.domain
}
