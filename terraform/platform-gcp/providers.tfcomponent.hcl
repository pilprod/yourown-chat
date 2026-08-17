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
    # 7.22+ provides ephemeral Secret Manager reads, so bootstrap credentials
    # can cross only write-only arguments and never enter Stack state.
    version = ">= 7.22.0, < 8.0.0"
  }
  # google_project_service_identity (the Cloud SQL service agent granted
  # encrypt/decrypt on the shared CMEK key) is a beta-only resource in this
  # provider line, so the kms component needs google-beta.
  google-beta = {
    source  = "hashicorp/google-beta"
    version = ">= 7.22.0, < 8.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
  helm = {
    source  = "hashicorp/helm"
    version = "~> 3.0"
  }
  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = "~> 2.37.0"
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

provider "helm" "this" {
  config {
    kubernetes = {
      host                   = component.gke_auth.host
      cluster_ca_certificate = component.gke_auth.cluster_ca_certificate
      token                  = component.gke_auth.access_token
    }
  }
}

provider "kubernetes" "this" {
  config {
    host                   = component.gke_auth.host
    cluster_ca_certificate = component.gke_auth.cluster_ca_certificate
    token                  = component.gke_auth.access_token
  }
}
