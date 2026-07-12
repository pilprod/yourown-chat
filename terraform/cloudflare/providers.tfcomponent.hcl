# ---------------------------------------------------------------------------
# CLOUDFLARE stack: provider requirements + configuration.
#
# Auth is mixed by necessity:
#   - Cloudflare carries the ONE static secret the whole setup needs -- a
#     zone-scoped API token supplied as an EPHEMERAL input from an HCP variable
#     set (store "varset" in cloudflare.tfdeploy.hcl). It never touches git or
#     state.
#   - GCP (google) is fully KEYLESS (WIF): needed only for the origin-TLS
#     Secret Manager containers this stack fills. Linked stacks cannot publish
#     SENSITIVE values, so the Origin CA private key never crosses a stack
#     boundary -- this stack writes it into Secret Manager itself.
#   - tls is only exercised when manage_origin_cert = true (Origin CA CSR/key).
# ---------------------------------------------------------------------------

required_providers {
  cloudflare = {
    source  = "cloudflare/cloudflare"
    version = ">= 4.40.0, < 5.0.0"
  }
  tls = {
    source  = "hashicorp/tls"
    version = ">= 4.0.0"
  }
  google = {
    source = "hashicorp/google"
    # external_credentials (WIF for Stacks) landed in google 6.30; pinned to a
    # recent 6.x in .terraform.lock.hcl. Kept on 6.x to avoid a 7.x migration.
    version = ">= 6.45.0, < 7.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
}

# --- Cloudflare: single ephemeral zone-scoped API token ---------------------
provider "cloudflare" "this" {
  config {
    api_token = var.cloudflare_api_token
  }
}

provider "tls" "this" {}

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

provider "random" "this" {}
