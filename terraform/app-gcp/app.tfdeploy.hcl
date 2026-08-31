# APP-GCP deployment `eu` (project yourown-chat, europe-west3). Linked to
# platform-gcp and cloudflare via upstream_input; keyless GCP auth via HCP
# Dynamic Provider Credentials -> WIF (no static keys).

locals {
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa     = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project   = "yourown-chat"
  gcp_region    = "europe-west3"
  apple_team_id = join("", ["6HSP", "UCB5ZA"])
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

    project_id               = local.gcp_project
    environment              = "prod"
    region                   = local.gcp_region
    apple_association_app_id = "${local.apple_team_id}.com.yourown.chat"

    # --- platform-gcp published values (linked stack, last-applied) -----------
    gke_cluster_id  = upstream_input.platform.gke_cluster_id
    gcs_bucket_name = upstream_input.platform.gcs_bucket_name
    # Exact address published by platform-gcp; used only to render the
    # production Mattermost /32 egress policy.
    cloudsql_private_ip                   = upstream_input.platform.cloudsql_private_ip
    cluster_dns_ip                        = upstream_input.platform.cluster_dns_ip
    workload_identity_emails              = upstream_input.platform.workload_identity_emails
    artifact_registry_location            = upstream_input.platform.artifact_registry_location
    artifact_registry_repository_id       = upstream_input.platform.artifact_registry_repository_id
    kagent_registry_repository_id         = upstream_input.platform.kagent_registry_repository_id
    kagent_staging_registry_repository_id = upstream_input.platform.kagent_staging_registry_repository_id
    kagent_registry_location              = upstream_input.platform.kagent_registry_location
    # Platform Helm chart repository (helm/platform profiles as OCI artifacts).
    helm_registry_repository_id = upstream_input.platform.helm_registry_repository_id
    cmek_key_id                 = upstream_input.platform.cmek_key_id
    workload_identity_members   = upstream_input.platform.workload_identity_members
    yourown_chat_server_enabled = upstream_input.platform.yourown_chat_server_enabled
    # The migration job consumes this once to create the first native user.
    identity_bootstrap_user_password_secret_id         = upstream_input.platform.identity_bootstrap_user_password_secret_id
    yourown_chat_identity_connection_secret_id         = upstream_input.platform.yourown_chat_identity_connection_secret_id
    yourown_chat_identity_runtime_connection_secret_id = upstream_input.platform.yourown_chat_identity_runtime_connection_secret_id
    additional_cloudsql_connection_secret_ids          = try(upstream_input.platform.additional_cloudsql_connection_secret_ids, {})
    agentgateway_platform = try(upstream_input.platform.agentgateway, {
      enabled                    = false
      namespace                  = "agentgateway-system"
      gateway_api_version        = "v1.6.0"
      gateway_class_name         = "agentgateway"
      controller_name            = "agentgateway.dev/agentgateway"
      chart_version              = "v1.5.0"
      service_account_name       = "agentgateway"
      read_cluster_role_name     = "agentgateway-agentgateway-system"
      deployer_cluster_role_name = "agentgateway-agentgateway-system-deployer"
    })
    agentgateway_public_ip_address    = try(upstream_input.platform.agentgateway_public_ip_address, null)
    agentgateway_public_ip_name       = try(upstream_input.platform.agentgateway_public_ip_name, null)
    yourown_chat_registration_enabled = true
    ingress_ip_address                = upstream_input.platform.ingress_ip_address
    calls_ip_address                  = upstream_input.platform.calls_ip_address

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
    # One-shot recovery toggles. Substrate stays true through its separately
    # reviewed bootstrap and application adoption applies, then returns false.
    adopt_existing_cluster_bootstrap_releases        = false
    adopt_existing_namespaces                        = false
    adopt_existing_substrate                         = false
    adopt_existing_substrate_compatibility_confirmed = false

    matterbridge_enabled = false

    # Per-server on/off lives in helm/mcp/values.yaml.
    mcp_servers_enabled = true

    # Wrapper-based delivery (service helm/release.yaml + platform workload
    # profiles). Stays off until the platform charts are published by the
    # chart publication rail and the owning service repositories carry
    # reviewed release wrappers.
    wrapper_releases_enabled = false

    temporal_enabled = upstream_input.platform.temporal_enabled

    # Derived from the cloudflare stack's published outputs -- origin_tls_ready
    # and zero_trust_ready are true when Secret Manager versions exist.
    # try() guards the initial bootstrap.
    zero_trust_enabled = try(upstream_input.cloudflare.zero_trust_ready, false)
    # Refresh the Cloudflare Portal catalog after every verified production MCP
    # rollout. Treat any OAuth-session regression as a release failure so it is
    # reproducible and visible instead of waiting for the periodic catalog sync.
    mcp_capability_sync_enabled = true

    # Service-owned inputs live with the app-gcp Stack. Credentials remain in
    # the approved secret control plane; these values are names, URLs and
    # immutable release pins.
    github_connection_name      = local.github_connection_name
    source_repositories         = local.source_repositories
    vendor_chart_bundles        = local.vendor_chart_bundles
    kagent_substrate_delivery   = local.kagent_substrate_delivery
    kagent_preview_publisher    = local.kagent_preview_publisher
    substrate_preview_publisher = local.substrate_preview_publisher
    image_name                  = "mattermost"
    # Stable assembly tags use dev -> smoke -> approval -> prod. Prerelease
    # tags and version branches are structurally limited to dev preview.
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
        branch_regex    = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
        delivery        = "preview"
        release_channel = "experimental"
      }
    }

    # Semver tag on the deploy repository (catalog role `deploy`) cuts a Cloud
    # Deploy release automatically.
    release_tag_regex = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    # Product backend and MCP workloads are independent repositories with
    # independent CI/tag triggers and build identities.
    mcp_release_tag_regex     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
    backend_release_tag_regex = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    extra_labels = { cost-center = "platform" }
  }
}
