# Stacks-level provider requirements and configuration.
# Stacks declare providers at the stack root and pass configured instances into
# components. Auth is intentionally NOT hardcoded here — see the deployments
# file and stacks/README.md for the HCP OIDC / store options.

required_providers {
  google = {
    source  = "hashicorp/google"
    version = "~> 6.0"
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

    # Sourced from an HCP variable set / store (see deployments.tfdeploy.hcl).
    # Leave null to use OIDC dynamic provider credentials configured in HCP.
    credentials = var.google_credentials
  }
}

provider "random" "this" {}
