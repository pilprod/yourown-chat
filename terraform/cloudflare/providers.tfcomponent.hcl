# ---------------------------------------------------------------------------
# CLOUDFLARE stack: provider requirements + configuration.
#
# This stack is deliberately GCP-free: it carries the ONE static secret the
# whole setup needs -- a zone-scoped Cloudflare API token supplied as an
# EPHEMERAL input from an HCP variable set (store "varset" in
# cloudflare.tfdeploy.hcl). It never touches git or state, and the third-party
# edge shares no credentials or blast radius with the keyless GCP stacks.
# tls is only exercised when manage_origin_cert = true (Origin CA CSR/key).
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
}

# --- Cloudflare: single ephemeral zone-scoped API token ---------------------
provider "cloudflare" "this" {
  config {
    api_token = var.cloudflare_api_token
  }
}

provider "tls" "this" {}
