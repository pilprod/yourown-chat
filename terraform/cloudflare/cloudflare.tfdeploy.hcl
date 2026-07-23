# CLOUDFLARE deployment `yourown-chat`: the zone's public edge. Linked to
# platform-gcp (ingress IP, CMEK, WI member). The API token (varset, ephemeral)
# is the one static secret; GCP auth is keyless (WIF), used only for the
# origin-TLS/tunnel Secret Manager containers this stack writes.

locals {
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa     = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project = "yourown-chat"
  gcp_region  = "europe-west3"
}

identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

# Cloudflare API token, injected from an HCP variable set (never in git/state).
store "varset" "cloudflare" {
  id       = "varset-wrrdzyQKCP2no9U6"
  category = "terraform"
}

upstream_input "platform" {
  type   = "stack"
  source = "app.terraform.io/papou-work/yourown-chat/platform-gcp"
}

deployment "yourown-chat" {
  inputs = {
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id = local.gcp_project
    region     = local.gcp_region

    # --- platform-gcp published values (linked stack, last-applied) -----------
    ingress_ip_address        = upstream_input.platform.ingress_ip_address
    cmek_key_id               = upstream_input.platform.cmek_key_id
    workload_identity_members = upstream_input.platform.workload_identity_members

    # Derived from the single root toggle: platform publishes a null ingress IP
    # when its public_ingress_enabled is false.
    public_ingress_enabled = upstream_input.platform.ingress_ip_address != null

    cloudflare_api_token = store.varset.cloudflare.cloudflare_api_token
    domain               = "yourown.chat"

    cloudflare_proxied            = true
    cloudflare_ssl_mode           = "strict"
    cloudflare_always_use_https   = "on"
    cloudflare_min_tls_version    = "1.3"
    cloudflare_dnssec_enabled     = true
    cloudflare_manage_origin_cert = true

    # Zero Trust (Access + Tunnel) for private services. PREREQUISITE Terraform
    # cannot do: the varset API token must carry ACCOUNT permissions (Cloudflare
    # Tunnel:Edit + Access: Apps and Policies:Edit) before applying. The flag is
    # the kill switch for the beta claude.ai <-> MCP-portal interop (docs/MCP.md);
    # the dev Mattermost browser path has no beta dependency.
    zero_trust_enabled        = true
    zero_trust_allowed_emails = ["ilya@papou.email", "popov.pilprod@gmail.com"]
    zero_trust_upstreams = {
      mcp-terraform        = "http://mcp-terraform.mcp-terraform.svc.cluster.local:8080"
      mcp-google-cloud     = "http://mcp-google-cloud.mcp-google-cloud.svc.cluster.local:8080"
      mcp-google-workspace = "http://mcp-google-workspace.mcp-google-workspace.svc.cluster.local:8000"
    }
  }
}

# Downstream contract for app-gcp (a bare component output is not consumable
# cross-stack -- only publish_output is).
publish_output "origin_tls_ready" {
  description = "True once the Cloudflare Origin CA cert/key Secret Manager versions exist. app-gcp derives manage_ingress_origin_tls from it."
  value       = deployment.yourown-chat.origin_tls_ready
}

publish_output "aop_enabled" {
  description = "Per-hostname Authenticated Origin Pulls toggle. app-gcp derives its ingress verify-client from it."
  value       = deployment.yourown-chat.aop_enabled
}

publish_output "zero_trust_ready" {
  description = "True once the Cloudflare Zero Trust tunnel token Secret Manager version exists. app-gcp derives zero_trust_enabled from it."
  value       = deployment.yourown-chat.zero_trust_ready
}
