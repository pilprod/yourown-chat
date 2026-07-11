# ---------------------------------------------------------------------------
# Unified stack: provider requirements + configuration.
#
# ONE Terraform Stack now owns the whole product (GCP platform, the image-build
# CI and the Cloudflare edge) as separate components in a single deployment.
# That collapses the previous three stacks into one working directory and
# removes every cross-stack hand-off (see README.md).
#
# Auth is mixed by necessity:
#   - GCP (google/google-beta) is fully KEYLESS: HCP Terraform Dynamic Provider
#     Credentials mint a short-lived OIDC JWT per run (identity_token block in
#     deployments.tfdeploy.hcl) which the provider exchanges through Workload
#     Identity Federation to impersonate a least-privilege SA. No SA keys or
#     JSON exist anywhere in this repo.
#   - Cloudflare has NO Workload Identity path, so it carries the one secret the
#     stack needs: a zone-scoped API token supplied as an EPHEMERAL input from an
#     HCP variable set (store "varset" in deployments.tfdeploy.hcl). It never
#     touches git or state, and it stays isolated from the GCP blast radius.
#   - tls is only exercised when manage_origin_cert = true (Origin CA CSR/key).
# ---------------------------------------------------------------------------

required_providers {
  google = {
    source = "hashicorp/google"
    # external_credentials (WIF for Stacks) landed in google 6.30; pinned to a
    # recent 6.x in .terraform.lock.hcl. Kept on 6.x to avoid a 7.x migration.
    version = ">= 6.45.0, < 7.0.0"
  }
  # google_project_service_identity (the Cloud SQL / Artifact Registry service
  # agents granted encrypt/decrypt on the shared CMEK key) is a beta-only
  # resource in this provider line, so the kms/image components need google-beta.
  google-beta = {
    source  = "hashicorp/google-beta"
    version = ">= 6.45.0, < 7.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
  cloudflare = {
    source  = "cloudflare/cloudflare"
    version = ">= 4.40.0, < 5.0.0"
  }
  tls = {
    source  = "hashicorp/tls"
    version = ">= 4.0.0"
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

# --- Cloudflare: single ephemeral zone-scoped API token ---------------------
provider "cloudflare" "this" {
  config {
    api_token = var.cloudflare_api_token
  }
}

provider "tls" "this" {}
