# Publishes approved platform Helm chart versions as immutable OCI artifacts.
#
# The former Helm platform policy, retained in the disconnected
# pilprod/yourown-chat-rules/public archive, documented publishing each
# platform chart version once, never overwriting it, and pinning it through an
# explicit service-wrapper dependency change. This module owns only the
# publication rail: a least-privilege build identity, a repo-scoped writer
# binding on the dedicated immutable-tag Helm chart repository published by
# platform-gcp, a durable evidence bucket and one canonical-branch Cloud Build
# trigger. The whole rail stays unmaterialized (count = 0) until app-gcp
# receives that repository from the linked platform stack. Chart content,
# schemas and tests stay in helm/platform and helm/test (see
# docs/HELM_PLATFORM.md). Nothing here deploys a workload.

locals {
  enabled             = var.chart_repository != null
  registry_host       = local.enabled ? "${var.chart_repository.location}-docker.pkg.dev" : ""
  chart_registry_path = local.enabled ? "${local.registry_host}/${var.project_id}/${var.chart_repository.repository_id}" : ""
  evidence_bucket     = "chart-evidence-${var.region}"
  count               = local.enabled ? 1 : 0
}

# --- Least-privilege publication identity ----------------------------------
resource "google_service_account" "chart_publish" {
  count = local.count

  project      = var.project_id
  account_id   = "chart-publish"
  display_name = "Platform Helm chart publisher"
  description  = "Lints, tests and pushes immutable platform chart versions to the unified Artifact Registry repository."
}

# Required so builds running as this SA can stream logs (CLOUD_LOGGING_ONLY).
resource "google_project_iam_member" "logs" {
  count = local.count

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.chart_publish[0].email}"
}

# Repo-scoped push on the dedicated immutable-tag Helm chart repository owned by
# platform-gcp (never project-wide writer, never the image repository). The
# writer role also covers the pull needed to compare an already published chart
# version with the packaged source before deciding to skip or fail.
resource "google_artifact_registry_repository_iam_member" "writer" {
  count = local.count

  project    = var.project_id
  location   = var.chart_repository.location
  repository = var.chart_repository.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.chart_publish[0].email}"
}

# --- Durable publication evidence -------------------------------------------
# Release evidence must outlive the artifact's useful life, so it has its own
# bucket: versioned, never expired by lifecycle, not publicly accessible and
# not force-destroyable. It is separate from the 30-day release-source staging
# bucket owned by deploy-release.
resource "google_storage_bucket" "evidence" {
  count = local.count

  project                     = var.project_id
  name                        = local.evidence_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = var.labels

  versioning {
    enabled = true
  }

  dynamic "encryption" {
    for_each = var.evidence_kms_key_name == null ? [] : [var.evidence_kms_key_name]
    content {
      default_kms_key_name = encryption.value
    }
  }
}

# Evidence objects are write-once (unique build ID in the object name), so the
# creator role is sufficient; the identity can neither read back nor delete
# evidence.
resource "google_storage_bucket_iam_member" "evidence_creator" {
  count = local.count

  bucket = google_storage_bucket.evidence[0].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.chart_publish[0].email}"
}

# Terraform (the apply SA) must actAs the publisher to create a trigger that
# runs as it.
resource "google_service_account_iam_member" "apply_acts_as_publisher" {
  count = local.count

  service_account_id = google_service_account.chart_publish[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

# --- Canonical-branch publication trigger ------------------------------------
# A push to the canonical branch that touches platform charts or their tests:
#   1. stages the pinned Helm binary;
#   2. builds local dependencies, lints every chart and runs the mandatory
#      platform test scripts (a chart tree without tests fails the build);
#   3. for every application chart: packages it and, when the version is
#      already published, pulls the published artifact and compares the full
#      extracted content (dependencies included). Identical content is
#      recorded as already published so an interrupted build can be retried;
#      different content fails the build because published versions are
#      immutable and must be bumped. Otherwise it pushes the chart;
#   4. records one evidence object per chart version in the evidence bucket.
# Immutability is decided against the registry, not against Git history, so a
# multi-commit push and a retried build are handled the same way.
resource "google_cloudbuild_trigger" "publish" {
  count = local.count

  project         = var.project_id
  location        = var.region
  name            = "platform-chart-publish"
  description     = "Lint, test and publish immutable platform Helm chart versions from branches matching ${var.branch_regex} to ${local.chart_registry_path}."
  service_account = google_service_account.chart_publish[0].id

  included_files = [
    "${var.chart_source_root}/**",
    var.chart_test_glob,
  ]

  repository_event_config {
    repository = var.repository_id
    push {
      branch = var.branch_regex
    }
  }

  build {
    timeout = var.build_timeout

    step {
      id         = "stage-helm"
      name       = var.helm_image
      entrypoint = "sh"
      args = [
        "-ceu",
        <<-EOT
          mkdir -p /workspace/bin
          cp "$$(command -v helm)" /workspace/bin/helm
          /workspace/bin/helm version --short
        EOT
      ]
    }

    step {
      id         = "verify-and-publish"
      name       = var.cloud_cli_image
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          set -o pipefail
          export PATH="/workspace/bin:$$PATH"
          helm version --short

          registry_host="${local.registry_host}"
          chart_registry="oci://${local.chart_registry_path}"
          source_root="${var.chart_source_root}"
          evidence_bucket="${google_storage_bucket.evidence[0].name}"
          mkdir -p /workspace/packages /workspace/compare /workspace/evidence

          chart_dirs=()
          for chart_file in "$$source_root"/*/Chart.yaml; do
            [ -f "$$chart_file" ] || continue
            chart_dirs+=("$$(dirname "$$chart_file")")
          done
          if [ "$${#chart_dirs[@]}" -eq 0 ]; then
            echo "No charts under $$source_root; nothing to verify or publish"
            exit 0
          fi

          # 1. Dependencies and lint. Platform charts may depend only on sibling
          #    file:// charts; a remote dependency is not a platform-owned input.
          for dir in "$${chart_dirs[@]}"; do
            if grep -Eq '^dependencies:' "$$dir/Chart.yaml"; then
              if grep -E '^[[:space:]]*repository:' "$$dir/Chart.yaml" | grep -Evq 'repository:[[:space:]]*"?file://'; then
                echo "Chart $$dir declares a non-local dependency repository; platform charts may depend only on sibling file:// charts" >&2
                exit 1
              fi
              helm dependency build "$$dir"
            fi
            helm lint --strict "$$dir"
          done

          # 2. Deterministic render, schema and policy tests are mandatory.
          #    helm lint does not replace them, so a chart tree without tests
          #    cannot publish.
          test_count=0
          for test_script in ${var.chart_test_glob}; do
            [ -f "$$test_script" ] || continue
            test_count=$$((test_count + 1))
            echo "Running $$test_script"
            bash "$$test_script"
          done
          if [ "$$test_count" -eq 0 ]; then
            echo "No platform test script matched ${var.chart_test_glob}; the platform policy tests are a required release gate and publication is refused" >&2
            exit 1
          fi

          # 3. Registry authentication with the build identity; no static credential.
          gcloud auth print-access-token \
            | helm registry login "$$registry_host" --username oauth2accesstoken --password-stdin

          # expand_nested unpacks dependency archives under charts/ so two chart
          # trees can be compared file by file regardless of archive timestamps.
          expand_nested() {
            local root="$$1"
            local archive
            while archive="$$(find "$$root" -path '*/charts/*.tgz' -print -quit)"; [ -n "$$archive" ]; do
              tar -xzf "$$archive" -C "$$(dirname "$$archive")"
              rm -f "$$archive"
            done
          }

          # 4. Publish application charts; compare content when the version exists.
          published=0
          resumed=0
          for dir in "$${chart_dirs[@]}"; do
            name="$$(helm show chart "$$dir" | awk '$$1=="name:"{gsub(/"/,"",$$2); print $$2}')"
            version="$$(helm show chart "$$dir" | awk '$$1=="version:"{gsub(/"/,"",$$2); print $$2}')"
            type="$$(helm show chart "$$dir" | awk '$$1=="type:"{gsub(/"/,"",$$2); print $$2}')"
            if [ -z "$$name" ] || [ -z "$$version" ]; then
              echo "Cannot read name and version from $$dir/Chart.yaml" >&2
              exit 1
            fi
            if ! printf '%s\n' "$$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then
              echo "Chart $$name version $$version is not plain SemVer MAJOR.MINOR.PATCH" >&2
              exit 1
            fi
            if [ "$${type:-application}" = "library" ]; then
              echo "Library chart $$name $$version is bundled into its dependents and is not published separately"
              continue
            fi

            package="$$(helm package "$$dir" --destination /workspace/packages | sed -n 's/^Successfully packaged chart and saved it to: //p')"
            if [ ! -f "$$package" ]; then
              echo "helm package did not produce an archive for $$name $$version" >&2
              exit 1
            fi
            package_sha="$$(sha256sum "$$package" | cut -d' ' -f1)"
            ref="$$chart_registry/$$name"
            publication=published
            digest=""

            if helm show chart "$$ref" --version "$$version" > /dev/null 2>&1; then
              compare="/workspace/compare/$$name-$$version"
              rm -rf "$$compare"
              mkdir -p "$$compare/local" "$$compare/remote"
              tar -xzf "$$package" -C "$$compare/local"
              pull_output="$$(helm pull "$$ref" --version "$$version" --untar --untardir "$$compare/remote" 2>&1)"
              printf '%s\n' "$$pull_output"
              digest="$$(printf '%s\n' "$$pull_output" | sed -n 's/^Digest: //p')"
              expand_nested "$$compare/local"
              expand_nested "$$compare/remote"
              if diff -r "$$compare/local/$$name" "$$compare/remote/$$name" > "$$compare/diff.txt"; then
                echo "Chart $$name version $$version is already published with identical content; resuming without a new push"
                publication=already-published
                resumed=$$((resumed + 1))
              else
                echo "Chart $$name version $$version is already published with different content. Published chart versions are immutable: bump the version in $$dir/Chart.yaml. Differences:" >&2
                head -n 50 "$$compare/diff.txt" >&2
                exit 1
              fi
            else
              push_output="$$(helm push "$$package" "$$chart_registry" 2>&1)"
              printf '%s\n' "$$push_output"
              digest="$$(printf '%s\n' "$$push_output" | sed -n 's/^Digest: //p')"
              if [ -z "$$digest" ]; then
                echo "helm push did not report a digest for $$name $$version" >&2
                exit 1
              fi
              published=$$((published + 1))
            fi

            evidence_dir="/workspace/evidence/$$name/$$version"
            mkdir -p "$$evidence_dir"
            evidence="$$evidence_dir/$BUILD_ID.json"
            printf '{"repository":"%s","source_revision":"%s","build_id":"%s","chart":"%s","version":"%s","reference":"%s:%s","publication":"%s","oci_digest":"%s","package_sha256":"%s","helm_version":"%s","lint":"passed","tests":"passed","test_scripts":%s,"published_at":"%s"}\n' \
              "$REPO_FULL_NAME" "$COMMIT_SHA" "$BUILD_ID" "$$name" "$$version" "$$ref" "$$version" "$$publication" "$$digest" "$$package_sha" "$$(helm version --short)" "$$test_count" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$$evidence"
            cat "$$evidence"
            gcloud storage cp "$$evidence" "gs://$$evidence_bucket/charts/$$name/$$version/$BUILD_ID.json"
          done
          echo "Published $$published and resumed $$resumed chart version(s) at $$chart_registry"
        EOT
      ]
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_publisher,
    google_artifact_registry_repository_iam_member.writer,
    google_storage_bucket_iam_member.evidence_creator,
    google_project_iam_member.logs,
  ]
}
