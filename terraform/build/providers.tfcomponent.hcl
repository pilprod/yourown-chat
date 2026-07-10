# ---------------------------------------------------------------------------
# Build stack: provider requirements + keyless configuration.
#
# This stack is deliberately separate from the platform stack (terraform/platform):
# it manages ONLY the Mattermost image-build CI (a Cloud Build 2nd-gen GitHub
# connection + repository + tag-triggered image builds pushing to Artifact
# Registry). It reuses the SAME keyless auth path (HCP OIDC -> GCP Workload
# Identity Federation -> apply-SA impersonation); no static credentials exist.
#
# google-beta is required for google_project_service_identity (the Cloud Build
# service agent), which is a beta-only resource.
# ---------------------------------------------------------------------------

required_providers {
  google = {
    source  = "hashicorp/google"
    version = ">= 6.45.0, < 7.0.0"
  }
  google-beta = {
    source  = "hashicorp/google-beta"
    version = ">= 6.45.0, < 7.0.0"
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
