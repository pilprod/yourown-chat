# Stacks-level provider requirements and configuration.
# Stacks declare providers at the stack root and pass configured instances into
# components. Authentication is keyless: the google provider uses HCP Terraform
# Dynamic Provider Credentials (OIDC) exchanged through GCP Workload Identity
# Federation. No static credentials or SA keys exist in this repo.

required_providers {
  google = {
    source = "hashicorp/google"
    # external_credentials (WIF for Stacks) landed in google 6.30; pinned to a
    # recent 6.x in .terraform.lock.hcl. Kept on 6.x to avoid a 7.x migration.
    version = ">= 6.45.0, < 7.0.0"
  }
  # google_project_service_identity (the Cloud SQL / Artifact Registry service
  # agents granted encrypt/decrypt on the shared CMEK key) is a beta-only
  # resource in this provider line, so the kms component needs google-beta too.
  google-beta = {
    source  = "hashicorp/google-beta"
    version = ">= 6.45.0, < 7.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
}

provider "google" "this" {
  config {
    project = var.project_id
    region  = var.region

    # Keyless: exchange the HCP OIDC token via Workload Identity Federation and
    # impersonate a least-privilege SA. Takes precedence over credentials/
    # access_token/GOOGLE_CREDENTIALS; nothing secret is stored in git or state.
    external_credentials {
      audience              = var.audience
      service_account_email = var.service_account_email
      identity_token        = var.identity_token
    }
  }
}

provider "google-beta" "this" {
  config {
    project = var.project_id
    region  = var.region

    # Same keyless WIF path as the google provider above.
    external_credentials {
      audience              = var.audience
      service_account_email = var.service_account_email
      identity_token        = var.identity_token
    }
  }
}

provider "random" "this" {}
