# Google Agent Registry was added to the Google provider after the platform
# stack's deliberately pinned 6.x line. Keep this provider-specific governance
# stack on 7.x so adopting the registry does not force an unrelated
# platform/app migration.

required_providers {
  google = {
    source  = "hashicorp/google"
    version = ">= 7.40.0, < 8.0.0"
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
