component "realm" {
  for_each = var.enabled ? toset(["production"]) : toset([])
  source = "./modules/realm"

  inputs = {
    project_id                        = var.project_id
    bootstrap_user_username           = var.bootstrap_user_username
    bootstrap_user_password_secret_id = var.bootstrap_user_password_secret_id
    realm_name                      = var.realm_name
    public_host                    = var.public_host
    broker_redirect_uris           = var.broker_redirect_uris
    terraform_service_account_user_id = var.terraform_service_account_user_id
    terraform_client_internal_id    = var.terraform_client_internal_id
    realm_management_client_id     = var.realm_management_client_id
    realm_admin_role_id             = var.realm_admin_role_id
    smtp_host                      = var.smtp_host
    smtp_from                      = var.smtp_from
  }

  providers = {
    google   = provider.google.this
    keycloak = provider.keycloak.this[each.key]
  }
}
