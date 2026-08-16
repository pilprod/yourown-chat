required_providers {
  keycloak = {
    source  = "keycloak/keycloak"
    version = "= 5.9.0"
  }
}

# The first configuration uses the short-lived bootstrap service account created
# by the platform runtime. After the realm-scoped Terraform client exists,
# bootstrap_mode is turned off and all later plans use client credentials with
# rights limited to the yourown-chat realm.
provider "keycloak" "this" {
  config {
    url              = var.keycloak_admin_url
    keycloak_version = var.keycloak_version
    realm            = var.bootstrap_mode ? "master" : var.realm_name
    client_id        = var.bootstrap_mode ? var.bootstrap_admin_client_id : var.terraform_client_id
    client_secret    = var.bootstrap_mode ? var.bootstrap_admin_client_secret : var.terraform_client_secret
    client_timeout   = 30
  }
}
