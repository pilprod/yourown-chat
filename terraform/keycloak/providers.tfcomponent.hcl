required_providers {
  keycloak = {
    source  = "keycloak/keycloak"
    version = "= 5.9.0"
  }
}

# Bootstrap authentication is a one-time recovery path. Normal plans use the
# permanent client scoped to the product realm; both secrets remain ephemeral
# provider inputs and never cross the component boundary.
provider "keycloak" "this" {
  for_each = var.enabled ? toset(["production"]) : toset([])

  config {
    url              = var.keycloak_admin_url
    keycloak_version = var.keycloak_version
    realm            = var.bootstrap_mode ? "master" : var.realm_name
    client_id        = var.bootstrap_mode ? var.bootstrap_admin_client_id : var.terraform_client_id
    client_secret    = var.bootstrap_mode ? var.bootstrap_admin_client_secret : var.terraform_client_secret
    client_timeout   = 30
  }
}
