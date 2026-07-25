terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
    # State-migration compatibility for the removed time_sleep resource.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14.0"
    }
  }
}
