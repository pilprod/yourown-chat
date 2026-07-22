locals {
  # Shared out-of-band Cloud Build 2nd-gen connection (console OAuth, README.md).
  connection_id      = "projects/${var.project_id}/locations/${var.region}/connections/${var.connection_name}"
  releaser_sa_id     = "releaser-${var.region}"
  source_bucket_name = "deploy-source-${var.region}"
}

resource "google_cloudbuildv2_repository" "this" {
  project           = var.project_id
  location          = var.region
  name              = var.repository_name
  parent_connection = local.connection_id
  remote_uri        = var.github_remote_uri
}

# Private staging bucket for the release source tarball (gcloud deploy releases
# create --source uploads here; Cloud Deploy reads it back to render).
resource "google_storage_bucket" "source" {
  project                     = var.project_id
  name                        = local.source_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true # disposable, 30-day-expiry tarballs
  labels                      = var.labels

  dynamic "encryption" {
    for_each = var.source_bucket_kms_key_name == null ? [] : [var.source_bucket_kms_key_name]
    content {
      default_kms_key_name = encryption.value
    }
  }

  # Source tarballs are ephemeral inputs to a release — expire them.
  lifecycle_rule {
    condition {
      age = var.source_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

# --- Least-privilege releaser identity --------------------------------------
resource "google_service_account" "releaser" {
  project      = var.project_id
  account_id   = local.releaser_sa_id
  display_name = "Cloud Deploy release cutter"
}

# Create releases + rollouts on THIS pipeline only (never a project-wide grant).
resource "google_clouddeploy_delivery_pipeline_iam_member" "releaser" {
  project  = var.project_id
  location = var.region
  name     = var.delivery_pipeline_name
  role     = "roles/clouddeploy.releaser"
  member   = "serviceAccount:${google_service_account.releaser.email}"
}

# The release create call polls a regional project-child operation, which needs
# a project-level read grant on top of the pipeline-scoped releaser role.
resource "google_project_iam_member" "releaser_clouddeploy_viewer" {
  project = var.project_id
  role    = "roles/clouddeploy.viewer"
  member  = "serviceAccount:${google_service_account.releaser.email}"
}

# Creating a release runs the render/deploy jobs as the Cloud Deploy execution
# SA, so the releaser must be able to actAs it.
resource "google_service_account_iam_member" "releaser_acts_as_exec" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.execution_service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.releaser.email}"
}

# Upload the source tarball to the staging bucket (bucket-scoped, not project).
resource "google_storage_bucket_iam_member" "releaser_source" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.releaser.email}"
}

# gcloud's source staging does a bucket metadata GET (CreateBucketIfNotExists)
# before uploading; objectAdmin lacks storage.buckets.get, so grant a minimal
# bucket-scoped reader too or the release cut 403s before it can upload.
resource "google_storage_bucket_iam_member" "releaser_source_bucket_read" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.releaser.email}"
}

# Stream build logs (mandatory when a build runs as a user-specified SA).
resource "google_project_iam_member" "releaser_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.releaser.email}"
}

# Terraform (the apply SA) must actAs the releaser to create a trigger that runs
# as it. Granted here so the trigger create call below is authorized.
resource "google_service_account_iam_member" "apply_acts_as_releaser" {
  service_account_id = google_service_account.releaser.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

# On a semver tag in the deploy repo, cut one Cloud Deploy release from
# source_subdir/ (auto-deploys to dev, promoted onward per the pipeline).
resource "google_cloudbuild_trigger" "release" {
  project         = var.project_id
  location        = var.region
  name            = "release"
  description     = "Cut a Cloud Deploy release from ${var.source_subdir}/ on git tags matching ${var.release_tag_regex}."
  service_account = google_service_account.releaser.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.this.id
    push {
      tag = var.release_tag_regex
    }
  }

  build {
    step {
      id         = "release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      dir        = var.source_subdir
      # Release name "rel-<tag>-<sha>-<build>": dots in the tag are sanitised to
      # `-` (release names disallow dots); the build fragment keeps it unique on
      # re-cuts. Escaping: Cloud Build built-ins ($TAG_NAME/$SHORT_SHA/$BUILD_ID)
      # keep a single `$`; bash constructs use `$$` (HCL passes it through, Cloud
      # Build unescapes to `$`). Braced `$${VAR}` must not appear.
      args = [
        "-ceu",
        <<-EOT
          safe_tag="$$(printf '%s' '$TAG_NAME' | tr '.' '-')"
          short_build="$$(printf '%s' '$BUILD_ID' | cut -c1-8)"
          gcloud deploy releases create "rel-$$safe_tag-$SHORT_SHA-$$short_build" \
            --project "${var.project_id}" \
            --region "${var.region}" \
            --delivery-pipeline "${var.delivery_pipeline_name}" \
            --source "." \
            --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
            --annotations "git-tag=$TAG_NAME"
        EOT
      ]
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_releaser,
    google_clouddeploy_delivery_pipeline_iam_member.releaser,
    google_service_account_iam_member.releaser_acts_as_exec,
    google_storage_bucket_iam_member.releaser_source,
    google_storage_bucket_iam_member.releaser_source_bucket_read,
    google_project_iam_member.releaser_clouddeploy_viewer,
    google_project_iam_member.releaser_logs,
  ]
}
