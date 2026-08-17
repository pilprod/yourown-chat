terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.22.0, < 8.0.0"
    }
    # google_project_service_identity (Cloud SQL / Artifact Registry service
    # agents) is a beta-only resource in this provider line.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.22.0, < 8.0.0"
    }
  }
}
