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
  for_each = var.delivery_pipelines

  project  = var.project_id
  location = var.region
  name     = each.key
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
  for_each = var.delivery_pipelines

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value.execution_service_account_email}"
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

resource "google_artifact_registry_repository_iam_member" "releaser_reader" {
  project    = var.project_id
  location   = var.mattermost_image_repository.location
  repository = var.mattermost_image_repository.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.releaser.email}"
}

# Terraform (the apply SA) must actAs the releaser to create a trigger that runs
# as it. Granted here so the trigger create call below is authorized.
resource "google_service_account_iam_member" "apply_acts_as_releaser" {
  service_account_id = google_service_account.releaser.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

# A single platform semver tag routes the frozen source to only the component
# pipelines changed since the preceding semver tag.
resource "google_cloudbuild_trigger" "release" {
  project         = var.project_id
  location        = var.region
  name            = "release"
  description     = "Route ${var.source_subdir}/ changes to Mattermost and/or MCP Cloud Deploy pipelines on ${var.release_tag_regex} tags."
  service_account = google_service_account.releaser.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.this.id
    push {
      tag = var.release_tag_regex
    }
  }

  build {
    step {
      id         = "route-components"
      name       = "gcr.io/cloud-builders/git"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          # Cloud Build's repository checkout is shallow. Fetching only tag
          # refs leaves their ancestry unavailable, so `git tag --merged`
          # finds no previous platform tag and the router treats every file as
          # changed. Expand the history before calculating the component diff.
          if [ "$$(git rev-parse --is-shallow-repository)" = "true" ]; then
            git fetch --unshallow --tags --force
          else
            git fetch --tags --force
          fi
          previous_tag="$$(git tag --merged "$COMMIT_SHA^" --sort=-version:refname |
            grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+$' | head -1 || true)"
          if [ -n "$$previous_tag" ]; then
            git diff --name-only "$$previous_tag" "$COMMIT_SHA" > /workspace/changed-files
          else
            git ls-tree -r --name-only "$COMMIT_SHA" > /workspace/changed-files
          fi
          echo "Previous platform tag: $${previous_tag:-<none>}"
          echo "Changed files routed by this release:"
          cat /workspace/changed-files
          printf '%s' "$$previous_tag" > /workspace/previous-platform-tag
        EOT
      ]
    }

    step {
      id         = "release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      dir        = var.source_subdir
      args = [
        "-ceu",
        <<-EOT
          safe_tag="$$(printf '%s' '$TAG_NAME' | tr '.' '-')"
          short_build="$$(printf '%s' '$BUILD_ID' | cut -c1-8)"

          previous_tag="$$(cat /workspace/previous-platform-tag)"
          changed="$$(cat /workspace/changed-files)"

          common_changed="$$(printf '%s\n' "$$changed" | grep -E '^helm/skaffold\\.yaml$' || true)"
          mattermost_changed="$$(printf '%s\n' "$$changed" | grep -E '^helm/(mattermost|matterbridge)/' || true)"
          mcp_changed="$$(printf '%s\n' "$$changed" | grep -E '^helm/mcp/' || true)"

          create_release() {
            pipeline="$$1"
            shift
            gcloud deploy releases create "$$pipeline-$$safe_tag-$SHORT_SHA-$$short_build" \
              --project "${var.project_id}" \
              --region "${var.region}" \
              --delivery-pipeline "$$pipeline" \
              --source "." \
              --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
              --annotations "git-tag=$TAG_NAME,git-sha=$COMMIT_SHA,previous-tag=$$previous_tag" \
              "$$@"
          }

          if [ -n "$$common_changed$$mattermost_changed" ]; then
            image_repo="${var.mattermost_image_repository.location}-docker.pkg.dev/${var.project_id}/${var.mattermost_image_repository.repository_id}/${var.mattermost_image_repository.image_name}"
            mattermost_tag="$$(gcloud artifacts docker tags list "$$image_repo" \
              --filter="tag~'/tags/v.*-patched$$'" \
              --format='value(tag)' | sort -V | tail -n1)"
            [ -n "$$mattermost_tag" ] || { echo "No v*-patched Mattermost image tag found"; exit 1; }
            create_release mattermost \
              --deploy-parameters "mattermost_dev_image=$$image_repo:$$mattermost_tag,mattermost_version=$$mattermost_tag"
          fi
          if [ "${var.mcp_enabled}" = "true" ]; then
            [ -z "$$common_changed$$mcp_changed" ] || create_release mcp
          elif [ -n "$$common_changed$$mcp_changed" ]; then
            echo "MCP deployment changes detected, but mcp_servers_enabled=false; skipping MCP release"
          fi

          if [ -z "$$common_changed$$mattermost_changed$$mcp_changed" ]; then
            echo "No Mattermost or MCP deployment changes in $TAG_NAME"
          fi
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
    google_artifact_registry_repository_iam_member.releaser_reader,
  ]
}
