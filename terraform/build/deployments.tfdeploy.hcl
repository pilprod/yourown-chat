# ---------------------------------------------------------------------------
# Build deployment. ONE deployment owns the unified container registry
# (docker) and watches the single source repository
# (github.com/pilprod/mattermost). It builds ONE image on a SINGLE tag pattern;
# that one artifact is promoted dev -> prod by Cloud Deploy (platform stack), not
# rebuilt per environment:
#   - tags matching ^v.*-patched$   -> docker/mattermost:<tag>
# The registry lives in the one project `yourown-chat`, europe-west3.
#
# AUTH: keyless path identical to the platform stack -- HCP mints an OIDC JWT
# (identity_token block), the google/google-beta providers exchange it via
# Workload Identity Federation and impersonate the SHARED least-privilege apply
# SA (terraform-apply@, the same single plan/apply account the platform stack
# uses -- see INIT.md). No dedicated build SA; no static
# credentials or SA keys exist anywhere.
#
# INDEPENDENCE: this stack does NOT depend on the platform stack. It enables its
# own APIs (cloudbuild, artifactregistry) via its project_services component and
# only READS the out-of-band github-pat secret. The minimal bootstrap (auth APIs +
# secretmanager), the shared apply-SA roles, the github-pat secret and the OAuth
# install id are all provisioned once in docs/INIT.md, so the build and platform
# stacks can be applied in ANY order. See docs/BUILD.md.
# ---------------------------------------------------------------------------

locals {
  # --- Keyless auth wiring (shared project `yourown-chat`) -------------------
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  # Shared apply SA -- the SAME single account the platform stack impersonates
  # (see INIT.md). It just needs a few extra build roles; see
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

    # Cloud Build GitHub App installation ID from the one-time OAuth authorize.
    # NUMERIC. See docs/BUILD.md. 0 is a sentinel; a `> 0` validation blocks the
    # plan until you set the real installation ID before the first apply.
    github_app_installation_id = 0

    # Secret Manager secret holding the GitHub PAT. Created and populated
    # out-of-band during bootstrap (see docs/INIT.md); this stack only reads
    # versions/latest of it.
    github_pat_secret_id = "github-pat"
    github_remote_uri    = "https://github.com/pilprod/mattermost.git"
    image_name           = "mattermost"

    # The container registry is PUBLIC -> no CMEK (null). The build stack has no
    # CMEK dependency on any other stack.
    artifact_registry_kms_key_name = null

    # One source repo, ONE unified registry, ONE image built on a single tag
    # pattern. The same artifact is promoted dev -> prod (Cloud Deploy), never
    # rebuilt per environment:
    #   v9.11.3-patched  -> docker/mattermost:v9.11.3-patched
    builds = {
      mattermost = { tag_regex = "^v.*-patched$" }
    }

    extra_labels = { cost-center = "platform-build" }
  }
}
