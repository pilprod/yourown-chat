# Publication of the platform Helm workload-profile charts (helm/platform) as
# immutable OCI artifacts. A platform release tag runs the platform chart test
# suite and pushes every chart version that the chart repository does not hold
# yet. An existing version is never rebuilt or overwritten: the repository has
# immutable tags and the step skips published versions, so a correction is
# always a new chart version.
locals {
  chart_publication = var.chart_publication_enabled && var.helm_chart_repository != null
}

resource "google_service_account" "chart_publisher" {
  count = local.chart_publication ? 1 : 0

  project      = var.project_id
  account_id   = "chart-publisher"
  display_name = "Platform Helm chart publisher"
}

resource "google_project_iam_member" "chart_publisher_logs" {
  count = local.chart_publication ? 1 : 0

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.chart_publisher[0].email}"
}

# Writer only on the chart repository; the publisher cannot touch images.
resource "google_artifact_registry_repository_iam_member" "chart_publisher_writer" {
  count = local.chart_publication ? 1 : 0

  project    = var.project_id
  location   = var.helm_chart_repository.location
  repository = var.helm_chart_repository.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.chart_publisher[0].email}"
}

resource "google_storage_bucket_iam_member" "chart_publisher_evidence" {
  count = local.chart_publication ? 1 : 0

  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.chart_publisher[0].email}"
}

resource "google_storage_bucket_iam_member" "chart_publisher_evidence_bucket_read" {
  count = local.chart_publication ? 1 : 0

  bucket = google_storage_bucket.source.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.chart_publisher[0].email}"
}

resource "google_service_account_iam_member" "apply_acts_as_chart_publisher" {
  count = local.chart_publication ? 1 : 0

  service_account_id = google_service_account.chart_publisher[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

resource "google_cloudbuild_trigger" "chart_publish" {
  count = local.chart_publication ? 1 : 0

  project         = var.project_id
  location        = var.region
  name            = "platform-charts"
  description     = "Test and publish missing helm/platform chart versions as immutable OCI artifacts on ${var.release_tag_regex} tags."
  service_account = google_service_account.chart_publisher[0].id

  repository_event_config {
    repository = google_cloudbuildv2_repository.this.id
    push {
      tag = var.release_tag_regex
    }
  }

  build {
    step {
      id         = "test-and-publish-charts"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        # The publisher runs from the tagged platform checkout itself.
        platform_dir="$$PWD"
        ${indent(8, local.helm_install_script)}
        bash helm/test/platform.test.sh
        ${indent(8, local.helm_registry_login_script)}

        mkdir -p /workspace/charts /workspace/chart-evidence
        printf 'platform-tag=%s\ngit-sha=%s\nbuild-id=%s\nregistry=%s\n' \
          "$TAG_NAME" "$COMMIT_SHA" "$BUILD_ID" "${local.chart_registry}" > /workspace/chart-evidence/publication.txt
        for chart in helm/platform/platform-*/; do
          name="$$(basename "$$chart")"
          version="$$(awk '$$1 == "version:" { print $$2; exit }' "$$chart/Chart.yaml")"
          if helm show chart "${local.chart_registry}/$$name" --version "$$version" >/dev/null 2>&1; then
            echo "$$name $$version is already published; immutable versions are never rebuilt"
            printf '%s %s already-published\n' "$$name" "$$version" >> /workspace/chart-evidence/publication.txt
            continue
          fi
          helm package "$$chart" --destination /workspace/charts >/dev/null
          archive="/workspace/charts/$$name-$$version.tgz"
          digest="$$(sha256sum "$$archive" | cut -d' ' -f1)"
          helm push "$$archive" "${local.chart_registry}" 2>&1 | tee "/workspace/chart-evidence/$$name-$$version.push.log"
          printf '%s %s published sha256:%s\n' "$$name" "$$version" "$$digest" >> /workspace/chart-evidence/publication.txt
        done
        cat /workspace/chart-evidence/publication.txt
        gcloud storage cp -r /workspace/chart-evidence \
          "gs://${google_storage_bucket.source.name}/evidence/platform-charts/$BUILD_ID/"
      EOT
      ]
    }

    timeout = "1800s"
    options { logging = "CLOUD_LOGGING_ONLY" }
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_chart_publisher,
    google_project_iam_member.chart_publisher_logs,
    google_artifact_registry_repository_iam_member.chart_publisher_writer,
    google_storage_bucket_iam_member.chart_publisher_evidence,
    google_storage_bucket_iam_member.chart_publisher_evidence_bucket_read,
  ]
}
