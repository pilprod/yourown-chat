# ---------------------------------------------------------------------------
# DNS records.
#   * apex A  -> the platform ingress IP, proxied (the public origin);
#   * www     -> apex CNAME, proxied (optional, on by default);
#   * extra   -> arbitrary records (MX/TXT/SPF/DKIM/DMARC/verification/...);
#   * CAA     -> restrict which CAs may issue for the zone (optional).
# ---------------------------------------------------------------------------

resource "cloudflare_record" "apex" {
  zone_id = data.cloudflare_zone.this.id
  name    = local.apex_record_name
  type    = "A"
  content = var.origin_ip
  proxied = tobool(var.proxied)
  ttl     = local.apex_ttl
  comment = var.record_comment
}

resource "cloudflare_record" "www" {
  count = var.manage_www ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
  name    = "www"
  type    = "CNAME"
  content = var.domain
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform (cloudflare component). www -> apex."
}

# Arbitrary extra records keyed by a stable logical name so plans stay stable.
resource "cloudflare_record" "extra" {
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

resource "cloudflare_record" "caa" {
  for_each = { for i, r in var.caa_records : tostring(i) => r }

  zone_id = data.cloudflare_zone.this.id
  name    = local.apex_record_name
  type    = "CAA"
  ttl     = var.dns_ttl

  data {
    flags = each.value.flags
    tag   = each.value.tag
    value = each.value.value
  }
}
