locals {
  # Shared out-of-band Cloud Build 2nd-gen connection (console OAuth, README.md).
  connection_id   = "projects/${var.project_id}/locations/${var.region}/connections/${var.connection_name}"
  image_repo_path = "${var.artifact_registry_location}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repository_id}/${var.image_name}"
}

resource "google_cloudbuildv2_repository" "this" {
  project           = var.project_id
  location          = var.region
  name              = var.repository_name
  parent_connection = local.connection_id
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

resource "google_clouddeploy_delivery_pipeline_iam_member" "releaser" {
  project  = var.project_id
  location = var.region
  name     = var.mattermost_delivery.pipeline_name
  role     = "roles/clouddeploy.releaser"
  member   = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "clouddeploy_viewer" {
  project = var.project_id
  role    = "roles/clouddeploy.viewer"
  member  = "serviceAccount:${google_service_account.build.email}"
}

resource "google_service_account_iam_member" "build_acts_as_exec" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.mattermost_delivery.execution_service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.build.email}"
}

resource "google_storage_bucket_iam_member" "release_source" {
  bucket = var.mattermost_delivery.source_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.build.email}"
}

resource "google_storage_bucket_iam_member" "release_source_bucket_read" {
  bucket = var.mattermost_delivery.source_bucket_name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.build.email}"
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
    # No `images` block: buildx pushes from inside the step (--push); listing
    # images would trigger a second redundant push.

    step {
      id   = "docker-build"
      name = "gcr.io/cloud-builders/docker"
      # buildx required: the Dockerfile uses RUN --mount=type=cache.
      env = [
        "DOCKER_BUILDKIT=1",
        "PIPELINE_TAG=$TAG_NAME",
        "PIPELINE_COMMIT_SHA=$COMMIT_SHA",
        "PIPELINE_BUILD_ID=$BUILD_ID",
      ]
      entrypoint = "bash"
      # Escaping: bash vars use the braceless $$VAR form (HCL passes `$$`
      # through, Cloud Build unescapes to `$`). Braced `$${VAR}` must not appear.
      args = [
        "-ceu",
        <<-EOT
          pipeline_tag="$$PIPELINE_TAG"
          [ -n "$$pipeline_tag" ] || pipeline_tag="manual"
          pipeline_build_date="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"

          docker buildx create --name cloudbuild --use || docker buildx use cloudbuild
          docker buildx build \
            --file=${var.dockerfile} \
            --cache-from=type=registry,ref="${local.image_repo_path}:buildcache" \
            --cache-to=type=registry,ref="${local.image_repo_path}:buildcache",mode=max \
            --no-cache-filter=server-builder,runtime \
            --build-arg BUILD_NUMBER="$$pipeline_tag" \
            --build-arg BUILD_HASH="$$PIPELINE_COMMIT_SHA" \
            --build-arg EE_BUILD_HASH="$$PIPELINE_BUILD_ID" \
            --build-arg BUILD_DATE="$$pipeline_build_date" \
            --tag "${local.image_repo_path}:$$pipeline_tag" \
            --tag "${local.image_repo_path}:latest" \
            --push \
            .
        EOT
      ]
    }

    step {
      id   = "checkout-deploy-source"
      name = "gcr.io/cloud-builders/git"
      args = [
        "clone",
        "--depth=1",
        "--branch=${var.mattermost_delivery.deploy_repository_ref}",
        var.mattermost_delivery.deploy_repository_uri,
        "/workspace/yourown-chat",
      ]
    }

    # A patched-source tag is a complete Mattermost release event. Only after
    # the image push succeeds do we freeze its digest and start dev -> prod.
    step {
      id         = "mattermost-release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          safe_tag="$$(printf '%s' '$TAG_NAME' | tr '.' '-')"
          short_build="$$(printf '%s' '$BUILD_ID' | cut -c1-8)"
          image="${local.image_repo_path}:$TAG_NAME"
          digest="$$(gcloud artifacts docker images describe "$$image" --format='value(image_summary.digest)')"

          gcloud deploy releases create "mattermost-$$safe_tag-$SHORT_SHA-$$short_build" \
            --project "${var.project_id}" \
            --region "${var.region}" \
            --delivery-pipeline "${var.mattermost_delivery.pipeline_name}" \
            --source "/workspace/yourown-chat/helm" \
            --gcs-source-staging-dir "gs://${var.mattermost_delivery.source_bucket_name}/source" \
            --deploy-parameters "mattermost_dev_image=${local.image_repo_path}:$TAG_NAME,mattermost_version=$TAG_NAME" \
            --annotations "source-repo=pilprod/mattermost,git-tag=$TAG_NAME,git-sha=$COMMIT_SHA,image-digest=$$digest"
        EOT
      ]
    }

    # Multi-stage Mattermost builds (webapp + server) are heavy; the default
    # build timeout is nowhere near enough.
    timeout = "3600s"

    options {
      # Mandatory when the build runs as a user-specified service account.
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_build,
    google_project_iam_member.build_logs,
    google_artifact_registry_repository_iam_member.writer,
    google_clouddeploy_delivery_pipeline_iam_member.releaser,
    google_project_iam_member.clouddeploy_viewer,
    google_service_account_iam_member.build_acts_as_exec,
    google_storage_bucket_iam_member.release_source,
    google_storage_bucket_iam_member.release_source_bucket_read,
  ]
}
