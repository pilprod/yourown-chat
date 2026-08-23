locals {
  connection_id            = "projects/${var.project_id}/locations/${var.region}/connections/${var.connection_name}"
  build_service_account_id = "kagent-preview-build"
  source_bucket_name       = "${var.project_id}-kagent-preview-${var.region}"
}

# The integration/release repository owns the source lock, qualification gates,
# image build and Skaffold source. The fork remains source-only and never
# publishes directly into the cluster.
resource "google_cloudbuildv2_repository" "this" {
  project           = var.project_id
  location          = var.region
  name              = var.repository_name
  parent_connection = local.connection_id
  remote_uri        = var.github_remote_uri
}

resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = local.build_service_account_id
  display_name = "kagent preview builder and releaser"
}

# User-specified Cloud Build identities must write their own Cloud Logging
# stream. No broad Cloud Build editor role is required.
resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Push is bounded to the one existing Docker repository, never project-wide.
resource "google_artifact_registry_repository_iam_member" "build_writer" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

# Release creation is bounded to the preview pipeline. That pipeline has only
# one target, so this identity has no path to a production rollout.
resource "google_clouddeploy_delivery_pipeline_iam_member" "build_releaser" {
  project  = var.project_id
  location = var.region
  name     = var.delivery_pipeline_name
  role     = "roles/clouddeploy.releaser"
  member   = "serviceAccount:${google_service_account.build.email}"
}

# Required to poll the regional child operation produced by release creation.
resource "google_project_iam_member" "build_clouddeploy_viewer" {
  project = var.project_id
  role    = "roles/clouddeploy.viewer"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Creating a release launches render/deploy/verify as the target execution SA.
resource "google_service_account_iam_member" "build_acts_as_exec" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.execution_service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.build.email}"
}

# Frozen Cloud Deploy source and qualification evidence are isolated from every
# other product release family. The bucket is short-lived, UBLA-only and uses
# the platform CMEK whenever the platform has CMEK enabled.
resource "google_storage_bucket" "source" {
  project                     = var.project_id
  name                        = local.source_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels

  dynamic "encryption" {
    for_each = var.source_bucket_kms_key_name == null ? [] : [var.source_bucket_kms_key_name]
    content {
      default_kms_key_name = encryption.value
    }
  }

  lifecycle_rule {
    condition {
      age = var.source_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_iam_member" "build_source_objects" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.build.email}"
}

# gcloud checks bucket metadata before uploading a --source archive.
resource "google_storage_bucket_iam_member" "build_source_bucket_read" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.build.email}"
}

# Bind the intended release-source bucket explicitly and avoid adding the
# generic project-wide storage.objectUser role. The Google-required project-level
# clouddeploy.jobRunner role still transitively contains object create/get/list;
# removing that residual breadth needs a separately qualified custom execution
# role or conditioned artifact-storage setup beyond this preview MVP.
resource "google_storage_bucket_iam_member" "execution_source_objects" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.execution_service_account_email}"
}

# The execution identity may pull only from the reviewed shared Docker
# repository. Its Artifact Registry permission is repository-scoped rather than
# the project-wide reader normally used by the generic Cloud Deploy module.
resource "google_artifact_registry_repository_iam_member" "execution_reader" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.execution_service_account_email}"
}

# Terraform needs actAs only to bind this exact identity to the trigger.
resource "google_service_account_iam_member" "apply_acts_as_build" {
  service_account_id = google_service_account.build.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

# There is intentionally one immutable-tag event and no branch or manual
# trigger. The repository-owned build file verifies the source lock, builds the
# exact fork commit once, records its digest/evidence, then cuts a preview-only
# Cloud Deploy release.
resource "google_cloudbuild_trigger" "preview" {
  project         = var.project_id
  location        = var.region
  name            = "kagent-preview"
  description     = "Build, qualify and deploy immutable kagent preview tags matching ${var.preview_tag_regex}."
  service_account = google_service_account.build.id
  filename        = var.cloudbuild_config_path

  repository_event_config {
    repository = google_cloudbuildv2_repository.this.id
    push {
      tag = var.preview_tag_regex
    }
  }

  substitutions = {
    _PROJECT_ID          = var.project_id
    _REGION              = var.region
    _ARTIFACT_REPOSITORY = var.artifact_registry_repository_id
    _DELIVERY_PIPELINE   = var.delivery_pipeline_name
    _INITIAL_TARGET      = var.initial_target_name
    _PREVIEW_TAG_REGEX   = var.preview_tag_regex
    _PREVIEW_LOCK        = var.preview_lock_path
    _CRDS_READY          = tostring(var.crds_ready)
    _CRD_BUNDLE_SHA256   = var.crd_bundle_sha256
    _SUBSTRATE_READY     = tostring(var.substrate_ready)
    _SUBSTRATE_VERSION   = var.substrate_version
    _EVIDENCE_BUCKET     = google_storage_bucket.source.name
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_build,
    google_project_iam_member.build_logs,
    google_artifact_registry_repository_iam_member.build_writer,
    google_clouddeploy_delivery_pipeline_iam_member.build_releaser,
    google_project_iam_member.build_clouddeploy_viewer,
    google_service_account_iam_member.build_acts_as_exec,
    google_storage_bucket_iam_member.build_source_objects,
    google_storage_bucket_iam_member.build_source_bucket_read,
    google_storage_bucket_iam_member.execution_source_objects,
    google_artifact_registry_repository_iam_member.execution_reader,
  ]
}
