locals {
  # The Cloud Build 2nd-gen GitHub connection is created out-of-band via the
  # console OAuth flow (see README.md) and shared across the stack; the deploy
  # repository is linked to it by its deterministic resource ID.
  connection_id = "projects/${var.project_id}/locations/${var.region}/connections/${var.connection_name}"

  # Regional names, mirroring the rest of the stack (europe-west3-*). The project
  # is already yourown-chat, so a project prefix would just repeat it. The GCS
  # bucket keeps only a role suffix (-deploy-source); note its name must be free in
  # the GLOBAL GCS namespace since it no longer carries the project id.
  releaser_sa_id     = "${var.region}-releaser"
  source_bucket_name = "${var.region}-deploy-source"
}

# --- 2nd-gen repository on the shared, out-of-band GitHub connection ---------
# The connection is authorized once in the Cloud Build console (OAuth) and lives
# outside Terraform; here we only link the deploy repo (holds helm/) to it.
resource "google_cloudbuildv2_repository" "this" {
  project           = var.project_id
  location          = var.region
  name              = var.repository_name
  parent_connection = local.connection_id
  remote_uri        = var.github_remote_uri
}

# --- Private source-staging bucket ------------------------------------------
# `gcloud deploy releases create --source=.` tars the render root and uploads it
# here; Cloud Deploy then reads it back to render. A dedicated bucket (rather than
# gcloud's default) keeps the location deterministic and the grant least-privilege.
resource "google_storage_bucket" "source" {
  project                     = var.project_id
  name                        = local.source_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false
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

# --- Tag-triggered release cut ----------------------------------------------
# On a semver tag (release_tag_regex) in the deploy repo, cut one Cloud Deploy
# release from source_subdir/. The release auto-deploys to the first stage and is
# promoted onward per the pipeline (prod gated by approval). The image itself is
# built separately (image CI) and only promoted here — this cuts the K8s release.
resource "google_cloudbuild_trigger" "release" {
  project         = var.project_id
  location        = var.region
  name            = "cut-release"
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
      id         = "cut-release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "gcloud"
      dir        = var.source_subdir
      # $SHORT_SHA / $BUILD_ID / $TAG_NAME are Cloud Build built-ins populated for
      # tag-triggered builds. The release name avoids dots (semver tags contain
      # them, which release names disallow); the tag is kept as an annotation.
      args = [
        "deploy", "releases", "create", "rel-$SHORT_SHA-$BUILD_ID",
        "--project", var.project_id,
        "--region", var.region,
        "--delivery-pipeline", var.delivery_pipeline_name,
        "--source", ".",
        "--gcs-source-staging-dir", "gs://${google_storage_bucket.source.name}/source",
        "--annotations", "git-tag=$TAG_NAME",
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
    google_project_iam_member.releaser_logs,
  ]
}
