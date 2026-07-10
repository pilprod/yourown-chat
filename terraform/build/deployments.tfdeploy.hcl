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

  # Shared CMEK key created + owned by the PLATFORM stack (its kms component).
  # Deterministic path -- the platform names the keyring regionally (europe-west3-
  # keyring) with a bare `cmek` key. The platform stack also grants this registry's
  # service agent encrypterDecrypter on it, so it MUST be applied first. Set to null
  # if the platform sets cmek_enabled = false.
  cmek_key_id = "projects/${local.gcp_project}/locations/${local.gcp_region}/keyRings/${local.gcp_region}-keyring/cryptoKeys/cmek"
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
    name_prefix    = "yourown-chat"

    # Cloud Build GitHub App installation ID from the one-time OAuth authorize.
    # NUMERIC. See docs/BUILD.md. 0 is a sentinel; a `> 0` validation blocks the
    # plan until you set the real installation ID before the first apply.
    github_app_installation_id = 0

    # Secret Manager secret holding the GitHub PAT (created + populated
    # out-of-band before apply; the connection reads versions/latest at create).
    github_pat_secret_id = "github-pat"
    github_remote_uri    = "https://github.com/pilprod/mattermost.git"
    image_name           = "mattermost"

    # CMEK for the registry, using the shared key the platform stack owns (see
    # local above). Keep in sync with the platform stack's cmek_enabled: set to
    # null here if CMEK is disabled there.
    artifact_registry_kms_key_name = local.cmek_key_id

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
