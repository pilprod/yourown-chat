locals {
  # Shared out-of-band Cloud Build 2nd-gen connection (console OAuth, README.md).
  connection_id              = "projects/${var.project_id}/locations/${var.region}/connections/${var.connection_name}"
  releaser_sa_id             = "releaser-${var.region}"
  source_bucket_name         = "deploy-source-${var.region}"
  artifact_repository_prefix = "${var.mattermost_image_repository.location}-docker.pkg.dev/${var.project_id}/${var.mattermost_image_repository.repository_id}"
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

resource "google_artifact_registry_repository_iam_member" "releaser_registry" {
  project    = var.project_id
  location   = var.mattermost_image_repository.location
  repository = var.mattermost_image_repository.repository_id
  # The same tag-trigger builds the MCP image before cutting its release. A
  # repository-scoped writer can push that image and read its immutable digest.
  role   = "roles/artifactregistry.writer"
  member = "serviceAccount:${google_service_account.releaser.email}"
}

moved {
  from = google_artifact_registry_repository_iam_member.releaser_reader
  to   = google_artifact_registry_repository_iam_member.releaser_registry
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
  description     = "Route Helm deployment and Docker MCP image changes to component Cloud Deploy pipelines on ${var.release_tag_regex} tags."
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
          previous_tag="$$(bash "${var.source_subdir}/previous-platform-tag.sh" "$COMMIT_SHA")"
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
      id         = "prepare-image-sources"
      name       = "gcr.io/cloud-builders/git"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          previous_tag="$$(cat /workspace/previous-platform-tag)"
          mattermost_changed="$$(bash route-components.sh \
            /workspace/changed-files mattermost "$$previous_tag")"

          if [ "$$mattermost_changed" = "true" ]; then
            rtcd_source=/workspace/rtcd-source
            git clone --no-checkout https://github.com/mattermost/rtcd.git "$$rtcd_source"
            git -C "$$rtcd_source" checkout --detach b3dee597998db880193b2fe863752cbfae8cdc89
            test "$$(git -C "$$rtcd_source" rev-parse HEAD)" = \
              b3dee597998db880193b2fe863752cbfae8cdc89
            git -C "$$rtcd_source" apply \
              "$$PWD/mattermost/rtcd/dependencies.patch"
            git -C "$$rtcd_source" diff --check
            test "$$(git -C "$$rtcd_source" diff --name-only | sort | tr '\n' ' ')" = \
              "go.mod go.sum "
          else
            echo "No Mattermost deployment changes; skipping RTCD source preparation"
          fi

          mcp_inputs_changed="$$(bash route-components.sh \
            /workspace/changed-files mcp)"

          if [ "${var.mcp_enabled}" = "true" ] && [ "$$mcp_inputs_changed" = "true" ]; then
            PREPARED_CONTEXT_ROOT="/workspace/image-sources" \
              bash ../docker/prepare-images.sh
          else
            echo "No enabled MCP image inputs changed; skipping source preparation"
          fi
        EOT
      ]
      dir = var.source_subdir
    }

    step {
      id         = "audit-mcp-images"
      name       = "node:22.22.0-bookworm-slim@sha256:dd9d21971ec4395903fa6143c2b9267d048ae01ca6d3ea96f16cb30df6187d94"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          if [ "${var.mcp_enabled}" = "true" ]; then
            CHANGED_FILES="/workspace/changed-files" \
              bash ../docker/audit-images.sh
          else
            echo "MCP is disabled; skipping image audits"
          fi
        EOT
      ]
      dir = var.source_subdir
    }

    step {
      id         = "build-mcp-images"
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          mcp_inputs_changed="$$(bash route-components.sh \
            /workspace/changed-files mcp)"

          if [ "${var.mcp_enabled}" = "true" ] && [ "$$mcp_inputs_changed" = "true" ]; then
            AR_PREFIX="${local.artifact_repository_prefix}" \
            IMAGE_TAG="$COMMIT_SHA" \
            BUILD_VERSION="$TAG_NAME" \
            VCS_REF="$COMMIT_SHA" \
            CHANGED_FILES="/workspace/changed-files" \
            PREPARED_CONTEXT_ROOT="/workspace/image-sources" \
            OUTPUT_DIR="/workspace" \
              bash ../docker/build-images.sh
          else
            echo "No enabled MCP image inputs changed; skipping image catalog"
          fi
        EOT
      ]
      dir = var.source_subdir
    }

    # Build the exact RTCD v1.2.6 source with the reviewed security dependency
    # patch. This avoids inheriting the known CVEs in Mattermost's published
    # binary while preserving a pinned and auditable upstream application tree.
    step {
      id         = "build-mattermost-rtcd"
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          previous_tag="$$(cat /workspace/previous-platform-tag)"
          mattermost_changed="$$(bash route-components.sh \
            /workspace/changed-files mattermost "$$previous_tag")"

          if [ "$$mattermost_changed" = "true" ]; then
            destination_image="${local.artifact_repository_prefix}/mattermost-rtcd:$COMMIT_SHA"
            docker build \
              --file mattermost/rtcd/Dockerfile \
              --tag "$$destination_image" \
              /workspace/rtcd-source
            docker push "$$destination_image"
            printf '%s' "$$destination_image" > /workspace/mattermost-rtcd-image-tag
          else
            echo "No Mattermost deployment changes; skipping RTCD security build"
          fi
        EOT
      ]
      dir = var.source_subdir
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
          mattermost_changed="$$(bash route-components.sh \
            /workspace/changed-files mattermost "$$previous_tag")"
          mcp_changed="$$(bash route-components.sh \
            /workspace/changed-files mcp "$$previous_tag")"

          create_release() {
            pipeline="$$1"
            release_id="$$2"
            annotations="$$3"
            shift 3
            gcloud deploy releases create "$$release_id" \
              --project "${var.project_id}" \
              --region "${var.region}" \
              --delivery-pipeline "$$pipeline" \
              --source "." \
              --skaffold-file "skaffold-$$pipeline.yaml" \
              --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
              --annotations "$$annotations" \
              "$$@"
          }

          if [ "$$mattermost_changed" = "true" ]; then
            image_repo="${local.artifact_repository_prefix}/${var.mattermost_image_repository.image_name}"
            mattermost_tag="$$(gcloud artifacts docker tags list "$$image_repo" \
              --filter="tag~'/tags/v.*-patched$$'" \
              --format='value(tag)' | sort -V | tail -n1)"
            [ -n "$$mattermost_tag" ] || { echo "No v*-patched Mattermost image tag found"; exit 1; }
            mattermost_tag="$${mattermost_tag##*/}"
            digest="$$(gcloud artifacts docker images describe \
              "$$image_repo:$$mattermost_tag" \
              --format='value(image_summary.digest)')"
            deploy_parameters="$$(bash mattermost-image-parameters.sh \
              "$$image_repo" \
              "$$digest")"
            rtcd_tag_ref="$$(cat /workspace/mattermost-rtcd-image-tag)"
            rtcd_digest="$$(gcloud artifacts docker images describe \
              "$$rtcd_tag_ref" \
              --format='value(image_summary.digest)')"
            rtcd_repository="$${rtcd_tag_ref%:*}"
            rtcd_image="$$rtcd_repository@$$rtcd_digest"
            deploy_parameters="$$deploy_parameters,mattermost_rtcd_image=$$rtcd_image"
            mattermost_release_id="$$(bash mattermost-release-id.sh \
              "$$mattermost_tag" \
              "$COMMIT_SHA" \
              "$BUILD_ID")"
            create_release \
              mattermost \
              "$$mattermost_release_id" \
              "git-tag=$TAG_NAME,git-sha=$COMMIT_SHA,build-id=$BUILD_ID,previous-tag=$$previous_tag,image-tag=$$mattermost_tag,image-digest=$$digest,rtcd-image-digest=$$rtcd_digest,rtcd-upstream=b3dee597998db880193b2fe863752cbfae8cdc89,rtcd-security-build=v1.2.6-yourown.1" \
              --deploy-parameters "$$deploy_parameters"
          fi
          if [ "${var.mcp_enabled}" = "true" ]; then
            if [ "$$mcp_changed" = "true" ]; then
              deploy_parameters="$$(AR_PREFIX="${local.artifact_repository_prefix}" \
                OUTPUT_DIR="/workspace" \
                bash ../docker/deploy-parameters.sh)"
              create_release \
                mcp \
                "mcp-$$safe_tag-$SHORT_SHA-$$short_build" \
                "git-tag=$TAG_NAME,git-sha=$COMMIT_SHA,build-id=$BUILD_ID,previous-tag=$$previous_tag" \
                --deploy-parameters "$$deploy_parameters"
            fi
          elif [ "$$mcp_changed" = "true" ]; then
            echo "MCP deployment changes detected, but mcp_servers_enabled=false; skipping MCP release"
          fi

          if [ "$$mattermost_changed" = "false" ] && [ "$$mcp_changed" = "false" ]; then
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
    google_artifact_registry_repository_iam_member.releaser_registry,
  ]
}
