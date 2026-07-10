# ---------------------------------------------------------------------------
# Cloudflare deployment. ONE deployment configures the public edge for the
# origin: a proxied apex A record for yourown.chat pointing at the platform
# stack's reserved ingress IP, plus baseline zone TLS settings (Full Strict,
# Always Use HTTPS, min TLS 1.2).
#
# AUTH: Cloudflare has no Workload Identity path, so unlike the GCP stacks this
# one carries a single secret -- a zone-scoped Cloudflare API token. It is NOT
# stored in git or in state: it is pulled from an HCP variable set via the store
# block below and passed as an ephemeral input. Create the token and the varset
# once during bootstrap (see docs/INIT.md).
#
# INDEPENDENCE: this stack does not run any GCP provider and has no live
# dependency on the platform stack. It only needs the reserved ingress IP, which
# the platform stack exposes as its ingress_ip_address output. That IP is stable
# by design (the reserved address survives LB re-creation), so it is copied here
# once as a literal rather than wired through a fragile live reference.
# ---------------------------------------------------------------------------

# Cloudflare zone-scoped API token, injected from an HCP variable set so it never
# touches git or state. Replace the id with your workspace's variable set ID and
# store the token under the key `cloudflare_api_token`. See docs/INIT.md.
store "varset" "cloudflare" {
  id       = "varset-REPLACE_WITH_HCP_VARSET_ID"
  category = "terraform"
}

deployment "cloudflare" {
  inputs = {
    cloudflare_api_token = store.varset.cloudflare.cloudflare_api_token

    domain = "yourown.chat"

    # Copy this from the platform stack output:
    #   terraform -chdir=terraform/platform output ingress_ip_address
    # The empty sentinel below fails the ingress_ip_address validation until you
    # paste the real reserved IP, which blocks an accidental apply.
    ingress_ip_address = ""

    proxied          = true
    ssl_mode         = "strict"
    always_use_https = "on"
    min_tls_version  = "1.2"
  }
}
