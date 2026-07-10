# ---------------------------------------------------------------------------
# Build-stack component wiring. This stack owns the unified container registry
# and the Mattermost image CI:
#   - project_services  : enables the APIs this stack uniquely needs
#                         (cloudbuild, artifactregistry) so it does not depend on
#                         the platform stack for them. The small BOOTSTRAP API set
#                         (auth + serviceusage + secretmanager) is enabled once by
#                         hand in docs/INIT.md.
#   - artifact_registry : ONE Artifact Registry Docker repo, named `docker`,
#                         shared by every
#                         environment. It lives here (not in the platform stack)
#                         because a single cross-environment registry has no
#                         natural home in the per-environment platform stack, and
#                         keeping it with the CI that writes to it avoids a
#                         platform<->build dependency cycle. The registry is
#                         PUBLIC, so it is deliberately NOT CMEK-encrypted.
#   - mattermost_image  : one Cloud Build 2nd-gen GitHub connection + repository
#                         (source: pilprod/mattermost) that reads the out-of-band
#                         github-pat secret, one least-privilege build service
#                         account (repo-scoped writer on the registry above) and a
#                         tag-triggered build that pushes ONE image on a single tag
#                         pattern (^v.*-patched$), promoted dev -> prod by Cloud
#                         Deploy rather than rebuilt per env.
#
# Independence: this stack enables its own APIs and only READS the out-of-band
# github-pat secret (created once in docs/INIT.md), so it can be applied in any
# order relative to the platform stack. See docs/BUILD.md.
# ---------------------------------------------------------------------------

locals {
  common_labels = merge({
    managed-by = "terraform"
    stack      = "yourown-chat-build"
  }, var.extra_labels)

  # APIs this stack owns. The bootstrap set (auth + serviceusage + secretmanager)
  # is enabled in docs/INIT.md; the platform stack owns the rest -- no overlap.
  activate_apis = [
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
  ]
}

# --- APIs owned by this stack -----------------------------------------------
component "project_services" {
  source = "./modules/project-services"

  inputs = {
    project_id    = var.project_id
    activate_apis = local.activate_apis
  }

  providers = {
    google = provider.google.this
  }
}

# --- Unified container registry (one repo for all environments) -------------
component "artifact_registry" {
  source = "./modules/artifact-registry"

  inputs = {
    project_id    = component.project_services.project_id
    location      = var.region
    repository_id = var.artifact_registry_repository_id
    description   = "Unified container images (Mattermost + future services), promoted by tag across environments."
    kms_key_name  = var.artifact_registry_kms_key_name
    labels        = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

# --- Mattermost image CI ----------------------------------------------------
component "mattermost_image" {
  source = "./modules/cloudbuild-image"

  inputs = {
    project_id     = component.project_services.project_id
    project_number = var.project_number
    region         = var.region

    apply_service_account_email = var.service_account_email

    github_app_installation_id = var.github_app_installation_id
    github_pat_secret_id       = var.github_pat_secret_id
    github_remote_uri          = var.github_remote_uri

    # Push every build to the ONE unified repository created above.
    artifact_registry_location      = component.artifact_registry.location
    artifact_registry_repository_id = component.artifact_registry.repository_id

    image_name = var.image_name
    builds     = var.builds
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}
