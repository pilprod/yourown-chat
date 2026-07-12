terraform {
  required_version = ">= 1.9.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.40.0, < 5.0.0"
    }
    # Only used when manage_origin_cert = true, to generate the CSR/key for the
    # Cloudflare Origin CA certificate. Declared unconditionally so the module
    # keeps a single, stable provider set.
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}
