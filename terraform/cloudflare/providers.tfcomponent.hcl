# ---------------------------------------------------------------------------
# Cloudflare stack: provider requirements + configuration.
#
# This stack is deliberately separate from the platform and build stacks. It
# manages the Cloudflare zone for the public origin (DNS, edge TLS/security
# settings, DNSSEC, WAF rules and optional origin TLS material). Keeping it
# separate isolates the Cloudflare API token from the GCP blast radius: the GCP
# stacks stay fully keyless (WIF/OIDC), and this stack carries the one secret
# Cloudflare needs.
#
# Unlike the GCP providers, Cloudflare has no Workload Identity path, so the API
# token is supplied as an ephemeral input (never persisted to state) and sourced
# from an HCP variable set in deployments.tfdeploy.hcl. The tls provider is only
# exercised when manage_origin_cert = true (to build the Origin CA CSR/key).
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

provider "cloudflare" "this" {
  config {
    api_token = var.cloudflare_api_token
  }
}

provider "tls" "this" {}
