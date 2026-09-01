locals {
  workload_image_paths = {
    control_api      = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-control-api"
    auth_api         = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-auth-api"
    transport_api    = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-transport-api"
    identity_api     = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-identity-api"
    identity_admin   = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-identity-admin"
    identity_migrate = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-identity-migrate"
  }

  source_repositories = {
    backend = {
      name       = var.backend_repository_name
      remote_uri = var.backend_github_remote_uri
    }
  }

  source_builders = {
    backend = {
      account_id   = "backend-build"
      display_name = "YourOwn.Chat server image builder"
    }
  }

  source_builder_pipelines = merge([
    for builder in keys(local.source_builders) : {
      for pipeline, settings in var.delivery_pipelines : "${builder}/${pipeline}" => {
        builder  = builder
        pipeline = pipeline
        settings = settings
      } if builder == "backend" && pipeline == "yourown-chat"
    }
  ]...)

  source_builds = {
    "${var.backend_repository_name}-ci" = {
      source   = "backend"
      branch   = var.backend_branch_regex
      tag      = null
      release  = false
      services = "control-api auth-api transport-api identity-api identity-admin identity-migrate"
    }
    "${var.backend_repository_name}-image" = {
      source   = "backend"
      branch   = null
      tag      = var.backend_release_tag_regex
      release  = true
      services = "control-api auth-api transport-api identity-api identity-admin identity-migrate"
    }
  }
}

# Source repositories are linked through the existing regional GitHub
# connection. The connection itself remains an out-of-band OAuth bootstrap;
# Terraform owns the repository links and every trigger thereafter.
resource "google_cloudbuildv2_repository" "source" {
  for_each = local.source_repositories

  project           = var.project_id
  location          = var.region
  name              = each.value.name
  parent_connection = local.connection_id
  remote_uri        = each.value.remote_uri
}

# The client-facing server build uses its own least-privilege identity.
resource "google_service_account" "source_build" {
  for_each = local.source_builders

  project      = var.project_id
  account_id   = each.value.account_id
  display_name = each.value.display_name
}

resource "google_project_iam_member" "source_build_logs" {
  for_each = local.source_builders

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.source_build[each.key].email}"
}

resource "google_project_iam_member" "source_on_demand_scan" {
  for_each = local.source_builders

  project = var.project_id
  role    = "roles/ondemandscanning.admin"
  member  = "serviceAccount:${google_service_account.source_build[each.key].email}"
}

resource "google_artifact_registry_repository_iam_member" "source_writer" {
  for_each = local.source_builders

  project    = var.project_id
  location   = var.mattermost_image_repository.location
  repository = var.mattermost_image_repository.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.source_build[each.key].email}"
}

# Wrapper releases vendor the pinned platform charts from the chart repository.
resource "google_artifact_registry_repository_iam_member" "source_chart_reader" {
  for_each = var.helm_chart_repository == null ? {} : local.source_builders

  project    = var.project_id
  location   = var.helm_chart_repository.location
  repository = var.helm_chart_repository.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.source_build[each.key].email}"
}

resource "google_storage_bucket_iam_member" "source_evidence_writer" {
  for_each = local.source_builders

  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.source_build[each.key].email}"
}

resource "google_storage_bucket_iam_member" "source_evidence_reader" {
  for_each = local.source_builders

  bucket = google_storage_bucket.source.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.source_build[each.key].email}"
}

resource "google_clouddeploy_delivery_pipeline_iam_member" "source_releaser" {
  for_each = local.source_builder_pipelines

  project  = var.project_id
  location = var.region
  name     = each.value.pipeline
  role     = "roles/clouddeploy.releaser"
  member   = "serviceAccount:${google_service_account.source_build[each.value.builder].email}"
}

resource "google_project_iam_member" "source_clouddeploy_viewer" {
  for_each = local.source_builders

  project = var.project_id
  role    = "roles/clouddeploy.viewer"
  member  = "serviceAccount:${google_service_account.source_build[each.key].email}"
}

resource "google_service_account_iam_member" "source_acts_as_deploy" {
  for_each = local.source_builder_pipelines

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value.settings.execution_service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.source_build[each.value.builder].email}"
}

resource "google_service_account_iam_member" "apply_acts_as_source_build" {
  for_each = local.source_builders

  service_account_id = google_service_account.source_build[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

# Source tags publish immutable, scanned server images. A main-branch build can
# never deploy.
resource "google_cloudbuild_trigger" "source_image" {
  for_each = local.source_builds

  project         = var.project_id
  location        = var.region
  name            = each.key
  description     = each.value.release ? "Build, attest and scan immutable ${each.value.source} images; deployment is coordinated by a platform tag." : "Verify ${each.value.source} main and publish commit-addressed scanned images without deployment."
  service_account = google_service_account.source_build[each.value.source].id

  repository_event_config {
    repository = google_cloudbuildv2_repository.source[each.value.source].id
    push {
      branch = each.value.branch
      tag    = each.value.tag
    }
  }

  build {
    step {
      id         = "verify-go"
      name       = "golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36"
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        go mod tidy
        go mod verify
        gofmt -w .
        git diff --exit-code -- '*.go' go.mod go.sum
        [ -z "$$(git status --porcelain -- go.mod go.sum)" ] || {
          echo "Cloud Build requires committed, tidy Go module locks" >&2
          exit 1
        }
        go vet ./...
        go test -race -coverprofile=/workspace/${each.value.source}-coverage.out ./...
        go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...
      EOT
      ]
    }

    step {
      id         = "build-and-attest"
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "bash"
      env        = ["DOCKER_BUILDKIT=1"]
      args = ["-ceu", <<-EOT
        image_tag="git-$COMMIT_SHA"
        version="$$image_tag"
        if [ -n "$TAG_NAME" ]; then image_tag="$TAG_NAME"; version="$TAG_NAME"; fi
        build_date="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        docker buildx create --name ${each.value.source}-cloudbuild --use || docker buildx use ${each.value.source}-cloudbuild
        for service in ${each.value.services}; do
          image_path="${local.artifact_repository_prefix}/${var.backend_image_prefix}-$$service"
          service_arg="--build-arg SERVICE=$$service"
          docker buildx build \
            --file Dockerfile \
            $$service_arg \
            --build-arg VERSION="$$version" \
            --build-arg COMMIT="$COMMIT_SHA" \
            --build-arg BUILD_DATE="$$build_date" \
            --tag "$$image_path:$$image_tag" \
            --attest=type=sbom \
            --attest=type=provenance,mode=max \
            --push .
        done
      EOT
      ]
    }

    step {
      id         = "resolve-and-scan"
      name       = local.scan_cli_image
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        image_tag="git-$COMMIT_SHA"
        if [ -n "$TAG_NAME" ]; then image_tag="$TAG_NAME"; fi
        for service in ${each.value.services}; do
          image_path="${local.artifact_repository_prefix}/${var.backend_image_prefix}-$$service"
          digest="$$(gcloud artifacts docker images describe "$$image_path:$$image_tag" --format='value(image_summary.digest)')"
          [ -n "$$digest" ] || { echo "Pushed $$service digest was not found" >&2; exit 1; }
          image="$$image_path@$$digest"
          printf '%s' "$$digest" > "/workspace/$$service-image-digest"
          printf '%s' "$$image" > "/workspace/$$service-image-uri"
          scan="$$(gcloud artifacts docker images scan "$$image" --remote --location=europe --format='value(response.scan)')"
          [ -n "$$scan" ] || { echo "On-Demand Scanning returned no scan ID for $$service" >&2; exit 1; }
          printf '%s' "$$scan" > "/workspace/$$service-scan-id"
          gcloud artifacts docker images list-vulnerabilities "$$scan" --format=json > "/workspace/$$service-vulnerabilities.json"
          gcloud artifacts docker images list-vulnerabilities "$$scan" \
            --format='value(vulnerability.effectiveSeverity)' > "/workspace/$$service-severities.txt"
          gcloud storage cp \
            "/workspace/$$service-image-digest" \
            "/workspace/$$service-image-uri" \
            "/workspace/$$service-scan-id" \
            "/workspace/$$service-severities.txt" \
            "/workspace/$$service-vulnerabilities.json" \
            "gs://${google_storage_bucket.source.name}/evidence/yourown-chat-${each.value.source}/$BUILD_ID/"
          if grep -Exq 'CRITICAL|HIGH' "/workspace/$$service-severities.txt"; then
            gcloud artifacts docker images list-vulnerabilities "$$scan" \
              --format='table(name.basename():label=OCCURRENCE,vulnerability.effectiveSeverity:label=SEVERITY,vulnerability.cvssScore:label=CVSS,vulnerability.shortDescription:label=VULNERABILITY)'
            echo "High or Critical vulnerability blocks $$service" >&2
            exit 1
          fi
          echo "Verified $$service image: $$image"
        done
        gcloud storage cp \
          /workspace/${each.value.source}-coverage.out \
          /workspace/*-image-digest \
          /workspace/*-image-uri \
          /workspace/*-scan-id \
          /workspace/*-severities.txt \
          /workspace/*-vulnerabilities.json \
          go.sum \
          "gs://${google_storage_bucket.source.name}/evidence/yourown-chat-${each.value.source}/$BUILD_ID/"
      EOT
      ]
    }

    step {
      id         = "checkout-platform"
      name       = "gcr.io/cloud-builders/git"
      entrypoint = "sh"
      args = ["-ceu", <<-EOT
        if [ -z "$TAG_NAME" ]; then exit 0; fi
        git clone --depth=1 --branch=main "${var.github_remote_uri}" /workspace/yourown-chat
      EOT
      ]
    }

    step {
      id         = "coordinate-tag-release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        if [ -z "$TAG_NAME" ]; then
          echo "Branch verification completed; no Cloud Deploy release is created"
          exit 0
        fi
        if [ "${var.wrapper_releases_enabled}" = "true" ]; then
          echo "Legacy chart release path is superseded by the wrapper-release step"
          exit 0
        fi

        safe_tag="$$(printf '%s' "$TAG_NAME" | tr '.+' '--')"
        platform_sha="$$(git -C /workspace/yourown-chat rev-parse HEAD)"

        if [ "${each.value.source}" = "backend" ] && [ "${var.server_enabled}" = "true" ]; then
          server_parameters=""
          server_digest_set_input=""
          for service in control-api auth-api transport-api identity-api identity-admin identity-migrate; do
            image_path="${local.artifact_repository_prefix}/${var.backend_image_prefix}-$$service"
            digest="$$(cat "/workspace/$$service-image-digest")"
            parameter="yourown_chat_$$(printf '%s' "$$service" | tr '-' '_')_image"
            [ -z "$$server_parameters" ] || server_parameters="$$server_parameters,"
            server_parameters="$$server_parameters$$parameter=$$image_path@$$digest"
            server_digest_set_input="$$server_digest_set_input$$digest\n"
          done
          server_digest_set="$$(printf '%b' "$$server_digest_set_input" | sha256sum | cut -d' ' -f1)"
          set +e
          server_output="$$(gcloud deploy releases create "yourown-chat-$$safe_tag" \
            --project "${var.project_id}" \
            --region "${var.region}" \
            --delivery-pipeline "yourown-chat" \
            --source "/workspace/yourown-chat/helm" \
            --skaffold-file "skaffold-yourown-chat.yaml" \
            --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
            --deploy-parameters "$$server_parameters" \
            --annotations "release-tag=$TAG_NAME,build-id=$BUILD_ID,image-set=$$server_digest_set,platform-sha=$$platform_sha" 2>&1)"
          server_status=$$?
          set -e
          if [ $$server_status -ne 0 ] && ! printf '%s' "$$server_output" | grep -q 'ALREADY_EXISTS'; then
            printf '%s\n' "$$server_output" >&2
            exit $$server_status
          fi
          printf '%s\n' "$$server_output"
        fi

      EOT
      ]
    }

    # Wrapper-based release: the service repository owns helm/release.yaml and
    # its platform-profile release wrappers; the public platform checkout owns
    # the assembler, the policy check and the pinned tooling. The release source
    # uploaded to Cloud Deploy contains only the generic Skaffold configuration,
    # the wrappers with vendored platform charts and the service values.
    step {
      id         = "wrapper-release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        if [ "${var.wrapper_releases_enabled}" != "true" ] || [ -z "$TAG_NAME" ]; then
          echo "Wrapper-based release path is disabled or this is not a release tag"
          exit 0
        fi
        if [ "${each.value.source}" = "backend" ] && [ "${var.server_enabled}" != "true" ]; then
          echo "yourown_chat_server_enabled=false; no server release is created"
          exit 0
        fi
        platform_dir=/workspace/yourown-chat
        ${indent(8, local.helm_install_script)}
        ${indent(8, local.helm_registry_login_script)}

        image_args=""
        for service in ${each.value.services}; do
          image_name="${var.backend_image_prefix}-$$service"
          image_args="$$image_args --image $$image_name=$$(cat "/workspace/$$service-image-uri")"
        done
        platform_sha="$$(git -C /workspace/yourown-chat rev-parse HEAD)"

        bash /workspace/yourown-chat/helm/platform/release/assemble.sh \
          --repo "$$PWD" \
          --out /workspace/release-source \
          --evidence /workspace/release-evidence \
          --chart-registry "${local.chart_registry}" \
          ${join(" ", [for profile in local.wrapper_profiles[each.value.source] : "--profile ${profile}"])} \
          ${local.wrapper_identity_args} \
          --secret-project "${var.project_id}" ${local.wrapper_dns_arg} \
          --source-revision "$COMMIT_SHA" \
          --platform-revision "$$platform_sha" \
          $$image_args

        safe_tag="$$(printf '%s' "$TAG_NAME" | tr '.+' '--')"
        pipeline="yourown-chat"
        mode="server"
        release_name="$$pipeline-$$safe_tag"
        set +e
        output="$$(gcloud deploy releases create "$$release_name" \
          --project "${var.project_id}" \
          --region "${var.region}" \
          --delivery-pipeline "$$pipeline" \
          --source /workspace/release-source \
          --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
          --deploy-parameters "$$(cat /workspace/release-source/deploy-parameters)" \
          --annotations "release-tag=$TAG_NAME,build-id=$BUILD_ID,source-sha=$COMMIT_SHA,platform-sha=$$platform_sha,render=platform-wrapper,mode=$$mode" 2>&1)"
        status=$$?
        set -e
        if [ $$status -ne 0 ] && ! printf '%s' "$$output" | grep -q 'ALREADY_EXISTS'; then
          printf '%s\n' "$$output" >&2
          exit $$status
        fi
        printf '%s\n' "$$output"
        gcloud storage cp -r /workspace/release-evidence \
          "gs://${google_storage_bucket.source.name}/evidence/yourown-chat-${each.value.source}/$BUILD_ID/release/"
      EOT
      ]
    }

    timeout = "3600s"
    options { logging = "CLOUD_LOGGING_ONLY" }
  }

  lifecycle {
    precondition {
      condition     = !var.wrapper_releases_enabled || var.helm_chart_repository != null
      error_message = "wrapper_releases_enabled requires helm_chart_repository (the platform Helm chart OCI repository published by platform-gcp)."
    }
    precondition {
      condition     = !var.wrapper_releases_enabled || var.cluster_dns_ip != ""
      error_message = "wrapper_releases_enabled requires cluster_dns_ip (the profiles require the cluster DNS address release parameter)."
    }
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_source_build,
    google_project_iam_member.source_build_logs,
    google_project_iam_member.source_on_demand_scan,
    google_artifact_registry_repository_iam_member.source_writer,
    google_storage_bucket_iam_member.source_evidence_writer,
    google_storage_bucket_iam_member.source_evidence_reader,
    google_clouddeploy_delivery_pipeline_iam_member.source_releaser,
    google_project_iam_member.source_clouddeploy_viewer,
    google_service_account_iam_member.source_acts_as_deploy,
  ]
}
