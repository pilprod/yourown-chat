# Publishes approved platform Helm chart versions as immutable OCI artifacts.
#
# The public Helm platform policy (.ai/helm-policy.md) requires every platform
# chart version to be published once, never overwritten, and pinned by service
# wrappers through an explicit dependency change. This module owns only the
# publication rail: a least-privilege build identity, a repo-scoped registry
# writer binding and one canonical-branch Cloud Build trigger. Chart content,
# schemas and tests stay in helm/platform and helm/test (see
# docs/HELM_PLATFORM.md). Nothing here deploys a workload.

locals {
  registry_host       = "${var.artifact_registry_location}-docker.pkg.dev"
  chart_registry_path = "${local.registry_host}/${var.project_id}/${var.artifact_registry_repository_id}/${var.chart_path_prefix}"
  evidence_bucket     = coalesce(var.evidence_bucket_name, "")
}

# --- Least-privilege publication identity ----------------------------------
resource "google_service_account" "chart_publish" {
  project      = var.project_id
  account_id   = "chart-publish"
  display_name = "Platform Helm chart publisher"
  description  = "Lints, tests and pushes immutable platform chart versions to the unified Artifact Registry repository."
}

# Required so builds running as this SA can stream logs (CLOUD_LOGGING_ONLY).
resource "google_project_iam_member" "logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.chart_publish.email}"
}

# Repo-scoped push on the ONE unified repository (never project-wide writer).
# The writer role also covers the read needed to detect an already published
# chart version before pushing.
resource "google_artifact_registry_repository_iam_member" "writer" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.chart_publish.email}"
}

# Evidence objects are write-once (unique build ID in the object name), so the
# creator role is sufficient; the identity can neither read back nor delete
# other evidence.
resource "google_storage_bucket_iam_member" "evidence_creator" {
  count = var.evidence_bucket_name == null ? 0 : 1

  bucket = var.evidence_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.chart_publish.email}"
}

# Terraform (the apply SA) must actAs the publisher to create a trigger that
# runs as it.
resource "google_service_account_iam_member" "apply_acts_as_publisher" {
  service_account_id = google_service_account.chart_publish.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

# --- Canonical-branch publication trigger ------------------------------------
# A push to the canonical branch that touches platform charts or their tests:
#   1. stages the pinned Helm binary;
#   2. computes which chart directories changed in this push;
#   3. builds local dependencies, lints every chart, runs the platform tests,
#      then publishes every application chart whose version is not yet in the
#      registry. A changed chart whose version is already published fails the
#      build: published versions are immutable and must be bumped;
#   4. records one evidence object per published version.
resource "google_cloudbuild_trigger" "publish" {
  project         = var.project_id
  location        = var.region
  name            = "platform-chart-publish"
  description     = "Lint, test and publish immutable platform Helm chart versions from branches matching ${var.branch_regex} to ${local.chart_registry_path}."
  service_account = google_service_account.chart_publish.id

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
      id         = "resolve-changed-charts"
      name       = "gcr.io/cloud-builders/git"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          # Cloud Build's repository checkout is shallow; the immutability rule
          # needs the first parent of the pushed commit to see what changed.
          if [ "$$(git rev-parse --is-shallow-repository)" = "true" ]; then
            git fetch --unshallow --force
          fi
          parent="$$(git rev-parse --verify --quiet "$${COMMIT_SHA}^" || true)"
          : > /workspace/changed-chart-dirs
          for chart_file in ${var.chart_source_root}/*/Chart.yaml; do
            [ -f "$$chart_file" ] || continue
            dir="$$(dirname "$$chart_file")"
            if [ -z "$$parent" ] || ! git diff --quiet "$$parent" "$COMMIT_SHA" -- "$$dir"; then
              echo "$$dir" >> /workspace/changed-chart-dirs
            fi
          done
          echo "Chart directories changed in this push (first parent $${parent:-<none>}):"
          cat /workspace/changed-chart-dirs
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
          evidence_bucket="${local.evidence_bucket}"
          mkdir -p /workspace/packages /workspace/evidence

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

          # 2. Deterministic render, schema and policy tests.
          test_found=false
          for test_script in ${var.chart_test_glob}; do
            [ -f "$$test_script" ] || continue
            test_found=true
            echo "Running $$test_script"
            bash "$$test_script"
          done
          [ "$$test_found" = true ] || echo "No test script matched ${var.chart_test_glob}; lint only"

          # 3. Registry authentication with the build identity; no static credential.
          gcloud auth print-access-token \
            | helm registry login "$$registry_host" --username oauth2accesstoken --password-stdin

          # 4. Publish application charts whose version is not yet published.
          published=0
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

            changed=false
            grep -Fxq "$$dir" /workspace/changed-chart-dirs && changed=true
            ref="$$chart_registry/$$name"
            if helm show chart "$$ref" --version "$$version" > /dev/null 2>&1; then
              if [ "$$changed" = true ]; then
                echo "Chart $$name version $$version is already published but its source changed in this push. Published chart versions are immutable: bump the version in $$dir/Chart.yaml." >&2
                exit 1
              fi
              echo "Chart $$name version $$version is already published and unchanged; skipping"
              continue
            fi

            package="$$(helm package "$$dir" --destination /workspace/packages | sed -n 's/^Successfully packaged chart and saved it to: //p')"
            if [ ! -f "$$package" ]; then
              echo "helm package did not produce an archive for $$name $$version" >&2
              exit 1
            fi
            push_output="$$(helm push "$$package" "$$chart_registry" 2>&1)"
            printf '%s\n' "$$push_output"
            digest="$$(printf '%s\n' "$$push_output" | sed -n 's/^Digest: //p')"
            if [ -z "$$digest" ]; then
              echo "helm push did not report a digest for $$name $$version" >&2
              exit 1
            fi

            package_sha="$$(sha256sum "$$package" | cut -d' ' -f1)"
            tests_result=none
            [ "$$test_found" = true ] && tests_result=passed
            evidence_dir="/workspace/evidence/$$name/$$version"
            mkdir -p "$$evidence_dir"
            evidence="$$evidence_dir/$BUILD_ID.json"
            printf '{"repository":"%s","source_revision":"%s","build_id":"%s","chart":"%s","version":"%s","reference":"%s:%s","oci_digest":"%s","package_sha256":"%s","helm_version":"%s","lint":"passed","tests":"%s","published_at":"%s"}\n' \
              "$REPO_FULL_NAME" "$COMMIT_SHA" "$BUILD_ID" "$$name" "$$version" "$$ref" "$$version" "$$digest" "$$package_sha" "$$(helm version --short)" "$$tests_result" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$$evidence"
            cat "$$evidence"
            if [ -n "$$evidence_bucket" ]; then
              gcloud storage cp "$$evidence" "gs://$$evidence_bucket/charts/$$name/$$version/$BUILD_ID.json"
            fi
            published=$$((published + 1))
          done
          echo "Published $$published chart version(s) to $$chart_registry"
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
    google_project_iam_member.logs,
  ]
}
