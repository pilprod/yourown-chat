# ---------------------------------------------------------------------------
# DNS records.
#   * apex A  -> the platform ingress IP, proxied (the public origin);
#   * www     -> proxied CNAME to apex + a 301 redirect to the apex (secondary,
#                canonical host is the apex; www just forwards);
#   * extra   -> arbitrary records (MX/TXT/SPF/DKIM/DMARC/verification/...);
#   * CAA     -> restrict which CAs may issue for the zone (optional).
# ---------------------------------------------------------------------------

resource "cloudflare_dns_record" "apex" {
  zone_id = data.cloudflare_zone.this.id
  name    = local.apex_record_name
  type    = "A"
  content = var.origin_ip
  proxied = tobool(var.proxied)
  ttl     = local.apex_ttl
  comment = var.record_comment
}

moved {
  from = cloudflare_record.apex
  to   = cloudflare_dns_record.apex
}

# www is a SECONDARY record: proxied so Cloudflare can 301 it to the apex (see
# cloudflare_ruleset.redirect_www below). The moved block preserves the
# pre-existing record identity during the v4 -> v5 type rename.
resource "cloudflare_dns_record" "www" {
  count = var.manage_www ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "www"
  type    = "CNAME"
  content = var.domain
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform (cloudflare component). Secondary; 301-redirected to the apex."
}

moved {
  from = cloudflare_record.www
  to   = cloudflare_dns_record.www
}

# 301 www -> apex so the apex stays the single canonical host (path + query
# preserved). Requires the proxied www record above so Cloudflare sees the request.
resource "cloudflare_ruleset" "redirect_www" {
  count = var.manage_www ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "redirect-www-to-apex"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [
    {
      action      = "redirect"
      description = "Redirect www to the apex (canonical host)"
      enabled     = true
      expression  = "(http.host eq \"www.${var.domain}\")"
      action_parameters = {
        from_value = {
          status_code           = 301
          preserve_query_string = true
          target_url = {
            expression = "concat(\"https://${var.domain}\", http.request.uri.path)"
          }
        }
      }
    }
  ]
}

# Arbitrary extra records keyed by a stable logical name so plans stay stable.
resource "cloudflare_dns_record" "extra" {
  for_each = var.extra_records

  zone_id  = data.cloudflare_zone.this.id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  proxied  = each.value.proxied
  ttl      = each.value.proxied ? 1 : each.value.ttl
  priority = each.value.priority
  comment  = each.value.comment
}

moved {
  from = cloudflare_record.extra
  to   = cloudflare_dns_record.extra
}

resource "cloudflare_dns_record" "caa" {
  for_each = { for i, r in var.caa_records : tostring(i) => r }

  zone_id = data.cloudflare_zone.this.id
  name    = local.apex_record_name
  type    = "CAA"
  ttl     = var.dns_ttl

  data = {
    flags = each.value.flags
    tag   = each.value.tag
    value = each.value.value
  }
}

moved {
  from = cloudflare_record.caa
  to   = cloudflare_dns_record.caa
}
