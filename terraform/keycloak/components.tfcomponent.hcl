component "realm" {
  for_each = var.enabled ? toset(["production"]) : toset([])
  source = "./modules/realm"

  inputs = {
    realm_name                      = var.realm_name
    public_host                    = var.public_host
    broker_redirect_uri            = var.broker_redirect_uri
    smtp_host                      = var.smtp_host
    smtp_from                      = var.smtp_from
  }

  providers = {
    keycloak = provider.keycloak.this[each.key]
  }
}
