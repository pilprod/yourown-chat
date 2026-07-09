# ---------------------------------------------------------------------------
# Build-stack component wiring. A single reusable module instance provisions the
# whole Mattermost image CI:
#   - one Cloud Build 2nd-gen GitHub connection + repository (source: pilprod/mattermost)
#   - one least-privilege build service account (repo-scoped AR writer only)
#   - N tag-triggered image builds (prod on ^v.*-patched$, dev on ^v.*patched-dev$)
#
# Loose coupling: this stack references the platform stack's per-environment
# Artifact Registry repositories by name convention (ycs-<env>-containers). It
# never creates them, so the platform stack stays the single owner of the
# registry and APIs and must be applied first.
# ---------------------------------------------------------------------------

locals {
  common_labels = merge({
    managed-by = "terraform"
    stack      = "yourown-chat-build"
  }, var.extra_labels)
}

component "mattermost_image" {
  source = "./modules/cloudbuild-image"

  inputs = {
    project_id     = var.project_id
    project_number = var.project_number
    region         = var.region
    name_prefix    = var.name_prefix

    apply_service_account_email = var.service_account_email

    github_app_installation_id = var.github_app_installation_id
    github_pat_secret_id       = var.github_pat_secret_id
    github_remote_uri          = var.github_remote_uri

    image_name = var.image_name
    builds     = var.builds
    labels     = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}
