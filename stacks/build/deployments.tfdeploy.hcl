# ---------------------------------------------------------------------------
# Build deployment. ONE deployment owns the unified container registry
# (ycs-containers) and watches the single source repository
# (github.com/pilprod/mattermost). It routes by git tag to the SAME image path
# -- images are promoted across environments by tag, not duplicated per env:
#   - tags matching ^v.*-patched$      -> ycs-containers/mattermost:<tag>   (prod)
#   - tags matching ^v.*patched-dev$   -> ycs-containers/mattermost:<tag>   (dev)
# The registry lives in the one project `yourown-chat`, europe-west3.
#
# AUTH: keyless path identical to the platform stack -- HCP mints an OIDC JWT
# (identity_token block), the google/google-beta providers exchange it via
# Workload Identity Federation and impersonate the SHARED least-privilege apply
# SA (terraform-apply@, the same single plan/apply account the platform stack
# uses -- see google_cloud_init.md). No dedicated build SA; no static
# credentials or SA keys exist anywhere.
#
# ORDERING: apply the platform stack FIRST (it enables the Cloud Build /
# Artifact Registry APIs). This stack then creates the registry + attaches the
# CI. See docs/BUILD.md for bootstrap (PAT secret, OAuth install id, and the
# few EXTRA roles the shared apply SA needs for the build resources).
# ---------------------------------------------------------------------------

locals {
  # --- Keyless auth wiring (shared project `yourown-chat`) -------------------
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  # Shared apply SA -- the SAME single account the platform stack impersonates
  # (see google_cloud_init.md). It just needs a few extra build roles; see
  # docs/BUILD.md. Its WIF binding already exists (org-scoped principalSet).
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
    # Keyless auth: OIDC JWT exchanged via WIF to impersonate the shared apply SA.
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

    # One source repo, ONE unified registry, routed by disjoint tag patterns to
    # the same image path. dev/prod images differ only by tag:
    #   v9.11.3-patched      -> prod
    #   v9.11.3-patched-dev  -> dev
    builds = {
      prod = { tag_regex = "^v.*-patched$" }
      dev  = { tag_regex = "^v.*patched-dev$" }
    }

    extra_labels = { cost-center = "platform-build" }
  }
}
