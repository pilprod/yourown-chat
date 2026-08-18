terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.22.0, < 8.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
