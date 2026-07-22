# APP-GCP deployment `eu` (project yourown-chat, europe-west3). Linked to
# platform-gcp and cloudflare via upstream_input; keyless GCP auth via HCP
# Dynamic Provider Credentials -> WIF (no static keys).

locals {
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa     = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project = "yourown-chat"
  gcp_region  = "europe-west3"
}

identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

upstream_input "platform" {
  type   = "stack"
  source = "app.terraform.io/papou-work/yourown-chat/platform-gcp"
}

upstream_input "cloudflare" {
  type   = "stack"
  source = "app.terraform.io/papou-work/yourown-chat/cloudflare"
}

deployment "eu" {
  inputs = {
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id  = local.gcp_project
    environment = "prod"
    region      = local.gcp_region

    # --- platform-gcp published values (linked stack, last-applied) -----------
    gke_cluster_id                  = try(upstream_input.platform.gke_cluster_id, null)
    gcs_bucket_name                 = try(upstream_input.platform.gcs_bucket_name, null)
    workload_identity_emails        = try(upstream_input.platform.workload_identity_emails, {})
    artifact_registry_location      = try(upstream_input.platform.artifact_registry_location, null)
    artifact_registry_repository_id = try(upstream_input.platform.artifact_registry_repository_id, null)
    cmek_key_id                     = try(upstream_input.platform.cmek_key_id, null)
    workload_identity_members       = try(upstream_input.platform.workload_identity_members, {})
    ingress_ip_address              = try(upstream_input.platform.ingress_ip_address, null)

    # Derived from the cloudflare stack's published outputs -- no hand-kept
    # mirror toggles. origin_tls_ready is true exactly when the Origin CA
    # cert/key Secret Manager versions exist; aop_enabled only flips the
    # ingress verify-client (the CA Secret is created regardless).
    # Protected with try(..., false) so app-gcp can plan/apply before cloudflare is applied.
    manage_ingress_origin_tls = try(upstream_input.cloudflare.origin_tls_ready, false)
    aop_enabled               = try(upstream_input.cloudflare.aop_enabled, false)

    # Chart pins -- bump deliberately.
    mattermost_operator_chart_version = "1.0.5"
    ingress_nginx_chart_version       = "4.15.1"
    # One-shot recovery toggles: flip true for a single adoption apply only.
    adopt_existing_cluster_bootstrap_releases = false
    adopt_existing_namespaces                 = false

    matterbridge_enabled = false

    # Per-server on/off lives in helm/mcp-servers/values.yaml.
    mcp_servers_enabled = true

    # Derived from the cloudflare stack's published outputs -- origin_tls_ready
    # and zero_trust_ready are true when Secret Manager versions exist.
    # try() guards against a not-yet-reapplied cloudflare stack missing the output.
    zero_trust_enabled = try(upstream_input.cloudflare.zero_trust_ready, false)



    # Cloud Build 2nd-gen GitHub connection, authorized once out-of-band in the
    # console (README.md); both repos are linked to it.
    github_connection_name = "pilprod-github"
    github_remote_uri      = "https://github.com/pilprod/mattermost.git"
    image_name             = "mattermost"
    # Build once on the tag pattern, promote the same artifact dev -> prod.
    builds = {
      mattermost = { tag_regex = "^v.*-patched$" }
    }

    # Semver tag on THIS repo cuts a Cloud Deploy release automatically.
    github_deploy_remote_uri = "https://github.com/pilprod/yourown-chat.git"
    release_tag_regex        = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    extra_labels = { cost-center = "platform" }
  }
}
