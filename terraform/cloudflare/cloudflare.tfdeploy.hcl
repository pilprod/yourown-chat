# ---------------------------------------------------------------------------
# CLOUDFLARE deployments. ONE deployment (`yourown-chat`) provisions the public
# edge for the zone. Named after the ZONE, not a region: a Cloudflare zone is a
# GLOBAL object (the edge network has no "eu"), so the deployment unit here is
# one domain -- a second deployment of this stack would be a second zone, not a
# second region (unlike the GCP stacks, whose `eu` deployments are regional).
#
# LINKED to platform-gcp via upstream_input "platform" (last-APPLIED outputs):
# the reserved static ingress IP for the apex A record, plus the CMEK key and
# the mattermost Workload Identity member for the secret containers. Linked
# stacks cannot publish SENSITIVE values, so the Origin CA private key is
# written into Secret Manager HERE and never crosses a stack boundary -- this
# stack publishes nothing downstream.
#
# AUTH is mixed by necessity:
#   - Cloudflare: the one zone-scoped API token, pulled from an HCP variable
#     set (store "varset") and passed as an EPHEMERAL input -- never in git or
#     state.
#   - GCP: keyless HCP Terraform Dynamic Provider Credentials -> Workload
#     Identity Federation (identity_token block), needed only for the
#     origin-TLS secrets. Bootstrap: README.md.
# ---------------------------------------------------------------------------

locals {
  # --- Keyless GCP auth wiring (project `yourown-chat`) ----------------------
  # STS token-exchange audience = full WIF provider resource name (leading //).
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  # Least-privilege SA impersonated after the exchange (never Owner/Editor).
  gcp_apply_sa = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project = "yourown-chat"
  gcp_region  = "europe-west3" # Frankfurt, Germany
}

# HCP mints this OIDC JWT once per run. Its `aud` claim must match the WIF
# provider's allowed-audiences, which is the full https://iam.googleapis.com/...
# provider URL (see README.md, gcloud ... --allowed-audiences=...).
identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

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

# --- yourown-chat: the zone's public edge in one deployment --------------------
deployment "yourown-chat" {
  inputs = {
    # --- Keyless GCP auth: OIDC JWT exchanged via WIF to impersonate apply SA --
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id = local.gcp_project
    region     = local.gcp_region

    # --- platform-gcp published values (linked stack, last-applied) -----------
    ingress_ip_address        = upstream_input.platform.ingress_ip_address
    cmek_key_id               = upstream_input.platform.cmek_key_id
    workload_identity_members = upstream_input.platform.workload_identity_members

    # Derived, not hand-mirrored: the public edge exists exactly when platform-gcp
    # reserved the static ingress IP this edge points at. platform publishes a
    # null ingress_ip_address when ITS public_ingress_enabled = false, so this
    # follows the single root toggle (platform.public_ingress_enabled) with no
    # second boolean to keep in sync.
    public_ingress_enabled = upstream_input.platform.ingress_ip_address != null

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
