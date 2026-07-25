resource "cloudflare_zero_trust_organization" "this" {
  account_id  = var.account_id
  name        = var.team_name
  auth_domain = "${var.team_name}.cloudflareaccess.com"
}

moved {
  from = cloudflare_zero_trust_access_organization.this
  to   = cloudflare_zero_trust_organization.this
}
