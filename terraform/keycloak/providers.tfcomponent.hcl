required_providers {
  keycloak = {
    source  = "keycloak/keycloak"
    version = "= 5.9.0"
  }
  terraform = {
    source = "terraform.io/builtin/terraform"
  }
}

provider "terraform" "builtin" {}

# The bootstrap identity has been retired. Every plan now authenticates only
# as the permanent client scoped to the product realm.
provider "keycloak" "this" {
  for_each = var.enabled ? toset(["production"]) : toset([])

  config {
    url              = var.keycloak_admin_url
    keycloak_version = var.keycloak_version
    realm            = var.realm_name
    client_id        = var.terraform_client_id
    client_secret    = var.terraform_client_secret
    client_timeout   = 30
  }
}
