# ---------------------------------------------------------------------------
# PLATFORM stack: provider requirements + configuration.
#
# GCP (google/google-beta) is fully KEYLESS: HCP Terraform Dynamic Provider
# Credentials mint a short-lived OIDC JWT per run (identity_token block in
# platform.tfdeploy.hcl) which the provider exchanges through Workload
# Identity Federation to impersonate a least-privilege SA. No SA keys or
# JSON exist anywhere in this repo. This stack touches NO third-party edge:
# the Cloudflare provider (and its API token) lives only in the cloudflare stack.
# ---------------------------------------------------------------------------

required_providers {
  google = {
    source = "hashicorp/google"
    # external_credentials (WIF for Stacks) landed in google 6.30; pinned to a
    # recent 6.x in .terraform.lock.hcl. Kept on 6.x to avoid a 7.x migration.
    version = ">= 6.45.0, < 7.0.0"
  }
  # google_project_service_identity (the Cloud SQL service agent granted
  # encrypt/decrypt on the shared CMEK key) is a beta-only resource in this
  # provider line, so the kms component needs google-beta.
  google-beta = {
    source  = "hashicorp/google-beta"
    version = ">= 6.45.0, < 7.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
}

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

provider "google-beta" "this" {
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