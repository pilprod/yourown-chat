locals {
  workload_image_paths = {
    control_api      = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-control-api"
    auth_api         = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-auth-api"
    transport_api    = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-transport-api"
    identity_api     = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-identity-api"
    identity_admin   = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-identity-admin"
    identity_migrate = "${local.artifact_repository_prefix}/${var.backend_image_prefix}-identity-migrate"
    workflow_worker  = "${local.artifact_repository_prefix}/${var.agents_image_prefix}-workflow-worker"
    activity_worker  = "${local.artifact_repository_prefix}/${var.agents_image_prefix}-activity-worker"
  }

  source_repositories = {
    backend = {
      name       = var.backend_repository_name
      remote_uri = var.backend_github_remote_uri
    }
    agents = {
      name       = var.agents_repository_name
      remote_uri = var.agents_github_remote_uri
    }
  }

  source_builders = {
    backend = {
      account_id   = "backend-build"
      display_name = "YourOwn.Chat server image builder"
    }
    agents = {
      account_id   = "agents-build"
      display_name = "YourOwn.Chat agent worker image builder"
    }
  }

  source_builder_pipelines = merge([
    for builder in keys(local.source_builders) : {
      for pipeline, settings in var.delivery_pipelines : "${builder}/${pipeline}" => {
        builder  = builder
        pipeline = pipeline
        settings = settings
      } if startswith(pipeline, "agents-") || (builder == "backend" && pipeline == "yourown-chat")
    }
  ]...)

  source_builds = {
    "yourown-chat-server-ci" = {
      source        = "backend"
      branch        = var.backend_branch_regex
      tag           = null
      release       = false
      services      = "control-api auth-api transport-api identity-api identity-admin identity-migrate"
      workflowcheck = false
    }
    "yourown-chat-server-image" = {
      source        = "backend"
      branch        = null
      tag           = var.backend_release_tag_regex
      release       = true
      services      = "control-api auth-api transport-api identity-api identity-admin identity-migrate"
      workflowcheck = false
    }
    "yourown-chat-agents-ci" = {
      source        = "agents"
      branch        = var.agents_branch_regex
      tag           = null
      release       = false
      services      = "workflow-worker activity-worker"
      workflowcheck = true
    }
    "yourown-chat-agents-image" = {
      source        = "agents"
      branch        = null
      tag           = var.agents_release_tag_regex
      release       = true
      services      = "workflow-worker activity-worker"
      workflowcheck = true
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

# The client-facing server and the agent compute have different trust
# boundaries. A compromised worker build cannot publish a server image (or the
# reverse), even though both write to the same project-wide registry.
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

# Source tags publish immutable, scanned images. The same release tag is
# required in both repositories: whichever build observes all three images
# first creates one atomic approval-gated Cloud Deploy release. A main-branch
# build can never deploy.
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
        if [ "${each.value.workflowcheck}" = "true" ]; then
          go run go.temporal.io/sdk/contrib/tools/workflowcheck@v0.5.0 ./...
        fi
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
          if [ "${each.value.source}" = "agents" ]; then
            image_path="${local.artifact_repository_prefix}/${var.agents_image_prefix}-$$service"
          fi
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
          if [ "${each.value.source}" = "agents" ]; then
            image_path="${local.artifact_repository_prefix}/${var.agents_image_prefix}-$$service"
          fi
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

        if [ "${var.agents_enabled}" != "true" ]; then
          echo "Server images are ready; the Terraform Temporal launch gate is closed, so no agent release is created"
          exit 0
        fi

        deploy_parameters=""
        digest_set_input=""
        for service in control-api workflow-worker activity-worker; do
          if [ "$$service" = "control-api" ]; then
            image_path="${local.artifact_repository_prefix}/${var.backend_image_prefix}-$$service"
          else
            image_path="${local.artifact_repository_prefix}/${var.agents_image_prefix}-$$service"
          fi
          digest="$$(gcloud artifacts docker images describe \
            "$$image_path:$TAG_NAME" --format='value(image_summary.digest)' 2>/dev/null || true)"
          if [ -z "$$digest" ]; then
            echo "Release tag $TAG_NAME is not complete yet: waiting for $$service from the matching repository tag"
            exit 0
          fi
          parameter="yourown_chat_$$(printf '%s' "$$service" | tr '-' '_')_image"
          [ -z "$$deploy_parameters" ] || deploy_parameters="$$deploy_parameters,"
          deploy_parameters="$$deploy_parameters$$parameter=$$image_path@$$digest"
          digest_set_input="$$digest_set_input$$digest\n"
        done

        release_name="agents-$$safe_tag"
        pipeline="${var.agents_runtime_enabled ? "agents-start" : "agents-pause"}"
        mode="${var.agents_runtime_enabled ? "running" : "paused"}"
        digest_set="$$(printf '%b' "$$digest_set_input" | sha256sum | cut -d' ' -f1)"

        set +e
        output="$$(gcloud deploy releases create "$$release_name" \
          --project "${var.project_id}" \
          --region "${var.region}" \
          --delivery-pipeline "$$pipeline" \
          --source "/workspace/yourown-chat/helm" \
          --skaffold-file "skaffold-agents.yaml" \
          --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
          --deploy-parameters "$$deploy_parameters" \
          --annotations "release-tag=$TAG_NAME,coordinator=${each.value.source},build-id=$BUILD_ID,image-set=$$digest_set,platform-sha=$$platform_sha,agent-mode=$$mode" 2>&1)"
        status=$$?
        set -e
        if [ $$status -ne 0 ]; then
          if printf '%s' "$$output" | grep -q 'ALREADY_EXISTS'; then
            echo "Coordinated release $$release_name already exists; the other source build won the race"
            exit 0
          fi
          printf '%s\n' "$$output" >&2
          exit $$status
        fi
        printf '%s\n' "$$output"
      EOT
      ]
    }

    timeout = "3600s"
    options { logging = "CLOUD_LOGGING_ONLY" }
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
