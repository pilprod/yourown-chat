required_providers {
  keycloak = {
    source  = "keycloak/keycloak"
    version = "= 5.9.0"
  }
}

# The first configuration uses the bootstrap service account created by the
# platform runtime. The permanent realm-scoped client remains configured here,
# but bootstrap_mode stays enabled until Terraform Stacks can safely pass its
# ephemeral write-only secret into a component without serializing it.
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
