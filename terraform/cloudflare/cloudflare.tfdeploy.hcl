# ---------------------------------------------------------------------------
# CLOUDFLARE deployments. ONE deployment (`eu`) provisions the public edge for
# yourown.chat: DNS (proxied apex A + www), edge TLS/security settings, DNSSEC,
# WAF rules and the Origin CA cert.
#
# LINKED STACKS chain: platform-gcp -> cloudflare -> app-gcp.
#   - upstream_input "platform" below delivers the reserved static ingress IP
#     (last-APPLIED platform-gcp output), so the apex A record can never point
#     at an address that does not exist yet;
#   - the publish_output blocks at the bottom hand the Origin CA cert/key to
#     the app-gcp stack, which pours them into the mattermost-origin-tls-*
#     Secret Manager containers.
# HCP orders all three stacks automatically along these edges.
#
# AUTH: no GCP here. The one zone-scoped Cloudflare API token is pulled from an
# HCP variable set (store "varset") and passed as an EPHEMERAL input -- never
# in git or state. Bootstrap: README.md.
# ---------------------------------------------------------------------------

# Cloudflare zone-scoped API token, injected from an HCP variable set so it never
# touches git or state. Replace the id with your workspace's variable set ID and
# store the token under the key `cloudflare_api_token`. See README.md.
store "varset" "cloudflare" {
  id       = "varset-wrrdzyQKCP2no9U6"
  category = "terraform"
}

# --- Linked platform-gcp stack ------------------------------------------------
# Consumes the publish_output values of the platform-gcp stack (same HCP
# project). Source format: app.terraform.io/<organization>/<hcp project>/<stack
# name> -- it must match the platform stack's name in HCP Terraform exactly.
upstream_input "platform" {
  type   = "stack"
  source = "app.terraform.io/papou-work/yourown-chat/platform-gcp"
}

# --- eu: the public edge in one deployment -------------------------------------
deployment "eu" {
  inputs = {
    # Reserved static IP from the platform-gcp stack (linked, last-applied).
    ingress_ip_address = upstream_input.platform.ingress_ip_address

    # MUST match the platform-gcp deployment's public_ingress_enabled (which
    # reserves the static IP this edge points at).
    public_ingress_enabled = true

    # Token from the varset; the zone and edge policy below.
    cloudflare_api_token          = store.varset.cloudflare.cloudflare_api_token
    domain                        = "yourown.chat"
    cloudflare_proxied            = true
    cloudflare_ssl_mode           = "strict"
    cloudflare_always_use_https   = "on"
    cloudflare_min_tls_version    = "1.3"
    cloudflare_dnssec_enabled     = true
    cloudflare_manage_origin_cert = true
  }
}

# --- Linked-stack contract: values the APP-GCP stack consumes ------------------
# Each publish_output republishes a stack output of the LAST APPLIED state of
# deployment.eu. The app-gcp stack references them as
#   upstream_input.cloudflare.<name>
# and HCP automatically triggers an app-gcp plan whenever an apply here changes
# one.
publish_output "origin_certificate_pem" {
  description = "Cloudflare Origin CA certificate (PEM) for the mattermost-origin-tls-cert secret."
  value       = deployment.eu.origin_certificate_pem
}

publish_output "origin_private_key_pem" {
  description = "Origin CA private key (PEM) for the mattermost-origin-tls-key secret."
  value       = deployment.eu.origin_private_key_pem
}
