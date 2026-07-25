# Cloudflare provider v5 removed cloudflare_zone_settings_override. Phase 1 of
# the migration deliberately forgets the aggregate v4 state object while
# leaving every remote zone setting unchanged. Do not replace this block with
# cloudflare_zone_setting resources until this change has been applied once
# with provider v4; see docs/CLOUDFLARE_V5_MIGRATION.md.
removed {
  from = cloudflare_zone_settings_override.this

  lifecycle {
    destroy = false
  }
}

# DNSSEC — enabling here returns a DS record to publish at the registrar.
resource "cloudflare_zone_dnssec" "this" {
  count = var.dnssec_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.this.id
}
