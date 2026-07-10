# ---------------------------------------------------------------------------
# Build-stack component wiring. This stack owns the unified container registry
# and the Mattermost image CI:
#   - kms               : a build-owned CMEK key (own keyring) that wraps ONLY
#                         the github-pat secret's DEK. It lives here so the build
#                         stack has NO CMEK dependency on the platform stack run.
#   - artifact_registry : ONE Artifact Registry Docker repo, named `docker`,
#                         shared by every
#                         environment. It lives here (not in the platform stack)
#                         because a single cross-environment registry has no
#                         natural home in the per-environment platform stack, and
#                         keeping it with the CI that writes to it avoids a
#                         platform<->build dependency cycle. The registry is
#                         PUBLIC, so it is deliberately NOT CMEK-encrypted.
#   - mattermost_image  : one Cloud Build 2nd-gen GitHub connection + repository
#                         (source: pilprod/mattermost), the CMEK-encrypted
#                         github-pat secret container it reads, one least-privilege
#                         build service account (repo-scoped writer on the registry
#                         above) and a tag-triggered build that pushes ONE image
#                         on a single tag pattern (^v.*-patched$), promoted
#                         dev -> prod by Cloud Deploy rather than rebuilt per env.
#
# Loose coupling: mattermost_image consumes artifact_registry's outputs and the
# kms key, so both are created before the connection/secret/writer binding. The
# platform stack still owns the APIs (artifactregistry/cloudbuild) and must be
# applied first. See docs/BUILD.md.
# ---------------------------------------------------------------------------

locals {
  common_labels = merge({
    managed-by = "terraform"
    stack      = "yourown-chat-build"
  }, var.extra_labels)
}

# --- Build-owned CMEK key (github-pat secret only) --------------------------
# Owned by THIS stack so build has no CMEK dependency on the platform stack run.
# Wraps the github-pat secret's DEK; the public container registry is NOT CMEK-
# encrypted.
component "kms" {
  source = "./modules/kms"

  inputs = {
    project_id = var.project_id
    location   = var.region
    labels     = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

# --- Unified container registry (one repo for all environments) -------------
component "artifact_registry" {
  source = "./modules/artifact-registry"

  inputs = {
    project_id    = var.project_id
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
    project_id     = var.project_id
    project_number = var.project_number
    region         = var.region
    name_prefix    = var.name_prefix

    apply_service_account_email = var.service_account_email

    github_app_installation_id = var.github_app_installation_id
    github_pat_secret_id       = var.github_pat_secret_id
    github_pat_kms_key_name    = component.kms.crypto_key_id
    github_remote_uri          = var.github_remote_uri

    # Push every build to the ONE unified repository created above.
    artifact_registry_location      = component.artifact_registry.location
    artifact_registry_repository_id = component.artifact_registry.repository_id

    image_name = var.image_name
    builds     = var.builds
    labels     = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}
