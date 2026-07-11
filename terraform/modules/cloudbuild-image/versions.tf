terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # google-beta was only needed for the removed Cloud Build service-agent
    # resource; the module now uses the base google provider exclusively.
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}
