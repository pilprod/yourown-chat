terraform {
  required_version = ">= 1.15.0"
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
}
