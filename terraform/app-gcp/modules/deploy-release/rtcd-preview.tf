# RTCD has its own source boundary and a deliberately one-way release path:
# release-* branches may build and deploy only to the dev-only preview pipeline.
resource "google_cloudbuildv2_repository" "rtcd" {
  project           = var.project_id
  location          = var.region
  name              = var.rtcd_repository_name
  parent_connection = local.connection_id
  remote_uri        = var.rtcd_github_remote_uri
}

resource "google_cloudbuild_trigger" "rtcd_preview" {
  project         = var.project_id
  location        = var.region
  name            = "rtcd-dev-preview"
  description     = "Test, attest, scan and deploy patched RTCD branches only to the Mattermost dev preview pipeline."
  service_account = google_service_account.releaser.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.rtcd.id
    push {
      branch = var.rtcd_preview_branch_regex
    }
  }

  build {
    step {
      id         = "test"
      name       = "golang:1.25.12-bookworm@sha256:ea341baa9bd5ba6784f6d7161ace70544349a6242d54d34a0fbfd2c4d51c9d58"
      entrypoint = "bash"
      args       = ["-ceu", "go mod verify && go test -mod=readonly ./..."]
    }

    step {
      id         = "build-attest-push"
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          image="${local.artifact_repository_prefix}/mattermost-rtcd:$COMMIT_SHA"
          docker buildx create --name rtcd-preview --use || docker buildx use rtcd-preview
          docker buildx build \
            --file build/yourown/Dockerfile \
            --build-arg RTCD_SOURCE_COMMIT="$COMMIT_SHA" \
            --build-arg RTCD_BUILD_VERSION="$BRANCH_NAME-$SHORT_SHA" \
            --build-arg RTCD_BUILD_DATE="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --tag "$$image" \
            --attest=type=sbom \
            --attest=type=provenance,mode=max \
            --push .
          printf '%s' "$$image" > /workspace/rtcd-image-tag
        EOT
      ]
    }

    step {
      id         = "scan"
      name       = "aquasec/trivy:0.66.0"
      entrypoint = "sh"
      args = [
        "-ceu",
        <<-EOT
          trivy image --exit-code 1 --severity HIGH,CRITICAL \
            --ignore-unfixed --no-progress "$$(cat /workspace/rtcd-image-tag)"
        EOT
      ]
    }

    step {
      id         = "deploy-dev-preview"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          git clone --depth 1 --branch main "${var.github_remote_uri}" /workspace/deploy
          image_repo="${local.artifact_repository_prefix}/${var.mattermost_image_repository.image_name}"
          mattermost_digest="$$(gcloud artifacts docker images describe \
            "$$image_repo:${var.rtcd_preview_mattermost_image_tag}" \
            --format='value(image_summary.digest)')"
          rtcd_tag_ref="$$(cat /workspace/rtcd-image-tag)"
          rtcd_digest="$$(gcloud artifacts docker images describe "$$rtcd_tag_ref" \
            --format='value(image_summary.digest)')"
          params="$$(bash /workspace/deploy/helm/mattermost-image-parameters.sh \
            "$$image_repo" "$$mattermost_digest")"
          params="$$params,mattermost_rtcd_image=$${rtcd_tag_ref%:*}@$$rtcd_digest"
          safe_branch="$$(printf '%s' "$BRANCH_NAME" | tr -c '[:alnum:]' '-' | sed -E 's/-+$//' | cut -c1-24)"
          release_id="rtcd-$${safe_branch}-$SHORT_SHA"
          gcloud deploy releases create "$$release_id" \
            --project "${var.project_id}" \
            --region "${var.region}" \
            --delivery-pipeline "mattermost-preview" \
            --source /workspace/deploy/helm \
            --skaffold-file skaffold-mattermost.yaml \
            --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
            --deploy-parameters "$$params" \
            --annotations "rtcd-git-sha=$COMMIT_SHA,rtcd-branch=$BRANCH_NAME,build-id=$BUILD_ID,rtcd-image-digest=$$rtcd_digest"
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
