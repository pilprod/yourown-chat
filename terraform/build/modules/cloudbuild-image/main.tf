locals {
  # Cloud Build service agent that the 2nd-gen connection uses to read the PAT.
  cloudbuild_agent = "serviceAccount:service-${var.project_number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"

  pat_secret_version = "${google_secret_manager_secret.github_pat.id}/versions/latest"

  # Single unified image path (no tag) shared by every build, e.g.
  # europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost
  image_repo_path = "${var.artifact_registry_location}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repository_id}/${var.image_name}"

  # Tagged reference built/pushed by each trigger. $TAG_NAME is a Cloud Build
  # built-in substitution set from the git tag that fired the trigger, so the
  # prod and dev triggers push the SAME path with different tags.
  image_ref = "${local.image_repo_path}:$TAG_NAME"
}

# --- GitHub PAT secret (container) -----------------------------------------
# The build stack owns the secret CONTAINER, encrypted at rest with the
# build-owned CMEK key (var.github_pat_kms_key_name; null = Google-managed).
# The secret VALUE (a fine-grained GitHub PAT) is never in git -- add the first
# version out-of-band after this secret is created, then apply again so the
# connection below can read versions/latest. User-managed replication pins the
# single replica to var.region, matching the CMEK key's location.
resource "google_secret_manager_secret" "github_pat" {
  project   = var.project_id
  secret_id = var.github_pat_secret_id
  labels    = var.labels

  replication {
    user_managed {
      replicas {
        location = var.region

        dynamic "customer_managed_encryption" {
          for_each = var.github_pat_kms_key_name == null ? [] : [1]
          content {
            kms_key_name = var.github_pat_kms_key_name
          }
        }
      }
    }
  }
}

# Ensure the Cloud Build service agent exists so we can grant it access to the
# PAT before the connection validates it (beta-only resource).
resource "google_project_service_identity" "cloudbuild" {
  provider = google-beta
  project  = var.project_id
  service  = "cloudbuild.googleapis.com"
}

# The connection's service agent must read the GitHub PAT secret.
resource "google_secret_manager_secret_iam_member" "agent_reads_pat" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.github_pat.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.cloudbuild_agent

  depends_on = [google_project_service_identity.cloudbuild]
}

# --- 2nd-gen GitHub connection + repository --------------------------------
resource "google_cloudbuildv2_connection" "github" {
  project  = var.project_id
  location = var.region
  name     = var.connection_name

  github_config {
    app_installation_id = var.github_app_installation_id
    authorizer_credential {
      oauth_token_secret_version = local.pat_secret_version
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.agent_reads_pat]
}

resource "google_cloudbuildv2_repository" "this" {
  project           = var.project_id
  location          = var.region
  name              = var.repository_name
  parent_connection = google_cloudbuildv2_connection.github.id
  remote_uri        = var.github_remote_uri
}

# --- Least-privilege build identity ----------------------------------------
resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = "img-build"
  display_name = "Mattermost image build"
}

# Required so builds running as this SA can stream logs (CLOUD_LOGGING_ONLY).
resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Repo-scoped push on the ONE unified repository (never project-wide writer).
resource "google_artifact_registry_repository_iam_member" "writer" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

# Terraform (the apply SA) must actAs the build SA to create triggers that run
# as it. Granted here so the trigger create call downstream is authorized.
resource "google_service_account_iam_member" "apply_acts_as_build" {
  service_account_id = google_service_account.build.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

# --- Tag-triggered image builds --------------------------------------------
resource "google_cloudbuild_trigger" "this" {
  for_each = var.builds

  project         = var.project_id
  location        = var.region
  name            = "${each.key}-image"
  description     = "Build + push the ${each.key} image on git tags matching ${each.value.tag_regex}."
  service_account = google_service_account.build.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.this.id
    push {
      tag = each.value.tag_regex
    }
  }

  build {
    images = [local.image_ref]

    step {
      id   = "docker-build"
      name = "gcr.io/cloud-builders/docker"
      args = ["build", "-t", local.image_ref, "-f", var.dockerfile, "."]
    }

    options {
      # Mandatory when the build runs as a user-specified service account.
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_build,
    google_project_iam_member.build_logs,
    google_artifact_registry_repository_iam_member.writer,
  ]
}
