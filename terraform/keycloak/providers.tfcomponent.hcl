required_providers {
  google = {
    source  = "hashicorp/google"
    version = ">= 7.22.0, < 8.0.0"
  }
  keycloak = {
    source  = "keycloak/keycloak"
    version = "= 5.9.0"
  }
}

# Read the one-time bootstrap credential through short-lived HCP Terraform
# credentials. No service-account key is stored in HCL or in a variable set.
provider "google" "this" {
  config {
    project = var.project_id
    region  = var.region

    external_credentials {
      audience              = var.audience
      service_account_email = var.service_account_email
      identity_token        = var.identity_token
    }
  }
}

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
