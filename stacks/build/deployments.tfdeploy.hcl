# ---------------------------------------------------------------------------
# Build deployment. ONE deployment watches the single source repository
# (github.com/pilprod/mattermost) and routes by git tag to the correct
# Artifact Registry repository -- it is NOT split into dev/prod deployments:
#   - tags matching ^v.*-patched$      -> ycs-prod-containers/mattermost
#   - tags matching ^v.*patched-dev$   -> ycs-dev-containers/mattermost
# Both target repos live in the one project `yourown-chat`, europe-west3.
#
# AUTH: identical keyless path to the platform stack -- HCP mints an OIDC JWT
# (identity_token block), the google/google-beta providers exchange it via
# Workload Identity Federation and impersonate the least-privilege apply SA.
# No static credentials or SA keys exist anywhere.
#
# ORDERING: apply the platform stack FIRST (it enables the Cloud Build /
# Artifact Registry APIs and creates the ycs-<env>-containers repositories).
# This stack then attaches the CI on top. See docs/BUILD.md for bootstrap.
# ---------------------------------------------------------------------------

locals {
  # --- Keyless auth wiring (shared project `yourown-chat`) -------------------
  gcp_wif_audience   = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa       = "terraform-apply@yourown-chat.iam.gserviceaccount.com"
  gcp_project        = "yourown-chat"
  gcp_project_number = "1086706391144"
  gcp_region         = "europe-west3" # Frankfurt, Germany (matches Artifact Registry)
}

identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

deployment "build" {
  inputs = {
    # Keyless auth: OIDC JWT exchanged via WIF to impersonate the apply SA.
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id     = local.gcp_project
    project_number = local.gcp_project_number
    region         = local.gcp_region
    name_prefix    = "ycs"

    # Cloud Build GitHub App installation ID from the one-time OAuth authorize.
    # NUMERIC. See docs/BUILD.md. 0 is a sentinel; a `> 0` validation blocks the
    # plan until you set the real installation ID before the first apply.
    github_app_installation_id = 0

    # Secret Manager secret holding the GitHub PAT (created + populated
    # out-of-band before apply; the connection reads versions/latest at create).
    github_pat_secret_id = "github-pat"
    github_remote_uri    = "https://github.com/pilprod/mattermost.git"
    image_name           = "mattermost"

    # One source repo, routed by tag to the per-environment AR repositories the
    # platform stack created (ycs-<env>-containers). Tag patterns are disjoint:
    #   v9.11.3-patched      -> prod only
    #   v9.11.3-patched-dev  -> dev only
    builds = {
      prod = {
        tag_regex                       = "^v.*-patched$"
        artifact_registry_location      = "europe-west3"
        artifact_registry_repository_id = "ycs-prod-containers"
      }
      dev = {
        tag_regex                       = "^v.*patched-dev$"
        artifact_registry_location      = "europe-west3"
        artifact_registry_repository_id = "ycs-dev-containers"
      }
    }

    extra_labels = { cost-center = "platform-build" }
  }
}
