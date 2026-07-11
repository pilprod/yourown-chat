terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0, < 7.0.0"
    }
    # Transitional: #30 removed the Cloud Build service-agent
    # (google_project_service_identity, beta-only) but pre-#30 state still holds
    # that resource. google-beta must stay declared/assigned so the next apply can
    # DESTROY the orphaned instance. Drop again once state is clean.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}
