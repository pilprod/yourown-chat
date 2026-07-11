terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0, < 7.0.0"
    }
    # Built-in provider backing terraform_data.pat_grant_gate (the PAT-read-grant
    # sequencing gate). Stacks requires it declared here and passed explicitly.
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }
}
