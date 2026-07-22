# CLOUDFLARE providers. Cloudflare uses a static API token (ephemeral varset
# input; Zero Trust needs it account-scoped). GCP is keyless (WIF), used only
# for the Secret Manager containers this stack writes. tls issues the origin/AOP
# certs.

required_providers {
  cloudflare = {
    source  = "cloudflare/cloudflare"
    version = ">= 4.40.0, < 5.0.0"
  }
  tls = {
    source  = "hashicorp/tls"
    version = ">= 4.0.0"
  }
  google = {
    source = "hashicorp/google"
    # external_credentials (WIF for Stacks) landed in google 6.30; pinned to a
    # recent 6.x in .terraform.lock.hcl. Kept on 6.x to avoid a 7.x migration.
    version = ">= 6.45.0, < 7.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
}

# --- Cloudflare: single ephemeral zone-scoped API token ---------------------
provider "cloudflare" "this" {
  config {
    api_token = var.cloudflare_api_token
  }
}

provider "tls" "this" {}

# --- GCP: keyless WIF (impersonate the least-privilege apply SA) -------------
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

provider "random" "this" {}
