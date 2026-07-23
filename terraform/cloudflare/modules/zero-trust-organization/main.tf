# The Zero Trust organization was bootstrapped by Cloudflare when the account
# was enrolled. Adopt it instead of attempting to create a second organization.
import {
  to = cloudflare_zero_trust_access_organization.this
  id = var.account_id
}

resource "cloudflare_zero_trust_access_organization" "this" {
  account_id  = var.account_id
  name        = var.team_name
  auth_domain = "${var.team_name}.cloudflareaccess.com"
}
