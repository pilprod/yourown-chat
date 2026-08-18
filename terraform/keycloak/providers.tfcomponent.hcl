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

# State decoding still needs the original provider schema, but this retired
# provider must never authenticate or call the Keycloak Admin API again.
provider "keycloak" "retired" {
  config {
    url              = var.keycloak_admin_url
    keycloak_version = var.keycloak_version
    initial_login    = false
    client_timeout   = 30
  }
}
