component "realm" {
  for_each = var.enabled ? toset(["production"]) : toset([])
  source = "./modules/realm"

  inputs = {
    realm_name                      = var.realm_name
    public_host                    = var.public_host
    broker_redirect_uri            = var.broker_redirect_uri
    terraform_service_account_user_id = var.terraform_service_account_user_id
    terraform_client_internal_id    = var.terraform_client_internal_id
    realm_management_client_id     = var.realm_management_client_id
    bootstrap_admin_client_secret  = var.bootstrap_admin_client_secret
    smtp_host                      = var.smtp_host
    smtp_from                      = var.smtp_from
  }

  providers = {
    keycloak  = provider.keycloak.this[each.key]
    terraform = provider.terraform.builtin
  }
}
