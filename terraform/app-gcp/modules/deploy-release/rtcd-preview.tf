# RTCD is a separately built release artifact. Its immutable source tag is
# built, attested and scanned here; the platform release trigger promotes the
# resulting digest only after source.lock is updated in this repository.
resource "google_cloudbuildv2_repository" "rtcd" {
  project           = var.project_id
  location          = var.region
  name              = var.rtcd_repository_name
  parent_connection = local.connection_id
  remote_uri        = var.rtcd_github_remote_uri
}

resource "google_cloudbuild_trigger" "rtcd_image" {
  project         = var.project_id
  location        = var.region
  name            = "rtcd-image"
  description     = "Test, attest, scan and publish immutable RTCD release images; platform release promotes the locked digest."
  service_account = google_service_account.releaser.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.rtcd.id
    push {
      tag = var.rtcd_release_tag_regex
    }
  }

  build {
    step {
      id         = "test"
      name       = "golang:1.25.12-bookworm@sha256:ea341baa9bd5ba6784f6d7161ace70544349a6242d54d34a0fbfd2c4d51c9d58"
      entrypoint = "bash"
      # Compile every package and its tests. RTCD's integration tests require
      # external services and are intentionally run in their dedicated suite;
      # this remains a deterministic Go test gate for each release build.
      args = ["-ceu", "go mod verify && go test -mod=readonly -run '^$' ./..."]
    }

    step {
      id         = "build-attest-push"
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          image="${local.artifact_repository_prefix}/mattermost-rtcd:$COMMIT_SHA"
          docker buildx create --name rtcd-image --use || docker buildx use rtcd-image
          docker buildx build \
            --file build/yourown/Dockerfile \
            --build-arg RTCD_SOURCE_COMMIT="$COMMIT_SHA" \
            --build-arg RTCD_BUILD_VERSION="$TAG_NAME" \
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
          token="$$(wget -qO- --header='Metadata-Flavor: Google' \
            http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | \
            sed -n 's/.*"access_token":"\\([^"\\]*\\)".*/\\1/p')"
          test -n "$$token"
          trivy image --exit-code 1 --severity HIGH,CRITICAL \
            --ignore-unfixed --no-progress \
            --username oauth2accesstoken --password "$$token" \
            "$$(cat /workspace/rtcd-image-tag)"
        EOT
      ]
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_releaser,
    google_service_account_iam_member.releaser_acts_as_exec,
    google_project_iam_member.releaser_logs,
    google_artifact_registry_repository_iam_member.releaser_registry,
  ]
}
