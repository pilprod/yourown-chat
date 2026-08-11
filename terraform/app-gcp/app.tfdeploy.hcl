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
    gke_cluster_id  = upstream_input.platform.gke_cluster_id
    gcs_bucket_name = upstream_input.platform.gcs_bucket_name
    # Exact address published by platform-gcp; used only to render the
    # production Mattermost /32 egress policy.
    cloudsql_private_ip             = upstream_input.platform.cloudsql_private_ip
    workload_identity_emails        = upstream_input.platform.workload_identity_emails
    artifact_registry_location      = upstream_input.platform.artifact_registry_location
    artifact_registry_repository_id = upstream_input.platform.artifact_registry_repository_id
    cmek_key_id                     = upstream_input.platform.cmek_key_id
    workload_identity_members       = upstream_input.platform.workload_identity_members
    ingress_ip_address              = upstream_input.platform.ingress_ip_address
    calls_ip_address                = upstream_input.platform.calls_ip_address

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

    # Per-server on/off lives in helm/mcp/values.yaml.
    mcp_servers_enabled = true

    # The delivery path and cheap persistent state stay present. This switch
    # chooses the static start/pause profile used by the next semver release.
    # Operational start/pause releases remain explicit and approval-gated.
    # The delivery plumbing and source triggers are prepared now. Runtime
    # release permission follows the platform-owned Temporal launch state.
    agent_platform_enabled         = true
    temporal_enabled               = upstream_input.platform.temporal_enabled
    agent_results_bucket           = try(upstream_input.platform.temporal_results_bucket_name, "")
    agent_platform_runtime_enabled = false

    # Derived from the cloudflare stack's published outputs -- origin_tls_ready
    # and zero_trust_ready are true when Secret Manager versions exist.
    # try() guards the initial bootstrap.
    zero_trust_enabled = try(upstream_input.cloudflare.zero_trust_ready, false)
    # Refresh the Cloudflare Portal catalog after every verified production MCP
    # rollout. Treat any OAuth-session regression as a release failure so it is
    # reproducible and visible instead of waiting for the periodic catalog sync.
    mcp_capability_sync_enabled = true

    # Cloud Build 2nd-gen GitHub connection, authorized once out-of-band in the
    # console (README.md); Mattermost, platform and backend repos are linked to it.
    github_connection_name = "pilprod-github"
    github_repository_name = "yourown-chat-mattermost"
    github_remote_uri      = "https://github.com/pilprod/yourown-chat-mattermost.git"
    github_web_repository_name = "yourown-chat-web"
    github_web_remote_uri      = "https://github.com/pilprod/yourown-chat-web.git"
    image_name             = "mattermost"
    # Stable assembly tags use dev -> smoke -> approval -> prod. Prerelease
    # tags and release branches are structurally limited to dev preview.
    builds = {
      mattermost = {
        tag_regex       = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
        delivery        = "production"
        release_channel = "production"
      }
      mattermost-prerelease = {
        tag_regex       = "^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9A-Za-z][0-9A-Za-z.-]*$"
        delivery        = "preview"
        release_channel = "prerelease"
      }
      mattermost-preview = {
        branch_regex    = "^release-[0-9]+\\.[0-9]+$"
        delivery        = "preview"
        release_channel = "experimental"
      }
    }

    # Semver tag on THIS repo cuts a Cloud Deploy release automatically.
    github_deploy_remote_uri = "https://github.com/pilprod/yourown-chat.git"
    release_tag_regex        = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    # Product backend and agent workloads are independent repositories with
    # independent CI/tag triggers and build identities.
    github_backend_remote_uri = "https://github.com/pilprod/yourown-chat-server.git"
    github_agents_remote_uri  = "https://github.com/pilprod/yourown-chat-agents.git"
    github_mcp_remote_uri     = "https://github.com/pilprod/yourown-chat-mcp.git"
    mcp_release_tag_regex     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
    backend_release_tag_regex = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
    agents_release_tag_regex  = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    extra_labels = { cost-center = "platform" }
  }
}
