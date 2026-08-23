locals {
  mcp_image_paths = {
    google_cloud     = "${local.artifact_repository_prefix}/mcp-google-cloud"
    terraform_stacks = "${local.artifact_repository_prefix}/mcp-terraform-stacks"
  }
  mcp_builds = {
    "yourown-chat-mcp-ci"    = { branch = var.mcp_branch_regex, tag = null, release = false }
    "yourown-chat-mcp-image" = { branch = null, tag = var.mcp_release_tag_regex, release = true }
  }
}

resource "google_cloudbuildv2_repository" "mcp_source" {
  project           = var.project_id
  location          = var.region
  name              = var.mcp_repository_name
  parent_connection = local.connection_id
  remote_uri        = var.mcp_github_remote_uri
}

resource "google_service_account" "mcp_build" {
  project      = var.project_id
  account_id   = "mcp-build"
  display_name = "YourOwn.Chat private MCP image builder"
}

resource "google_project_iam_member" "mcp_build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_project_iam_member" "mcp_on_demand_scan" {
  project = var.project_id
  role    = "roles/ondemandscanning.admin"
  member  = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_artifact_registry_repository_iam_member" "mcp_writer" {
  project    = var.project_id
  location   = var.mattermost_image_repository.location
  repository = var.mattermost_image_repository.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_artifact_registry_repository_iam_member" "mcp_chart_reader" {
  count = var.helm_chart_repository == null ? 0 : 1

  project    = var.project_id
  location   = var.helm_chart_repository.location
  repository = var.helm_chart_repository.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_clouddeploy_delivery_pipeline_iam_member" "mcp_source_releaser" {
  for_each = { for name, value in var.delivery_pipelines : name => value if name == "mcp" }

  project  = var.project_id
  location = var.region
  name     = each.key
  role     = "roles/clouddeploy.releaser"
  member   = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_project_iam_member" "mcp_clouddeploy_viewer" {
  project = var.project_id
  role    = "roles/clouddeploy.viewer"
  member  = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_service_account_iam_member" "mcp_acts_as_exec" {
  for_each = { for name, value in var.delivery_pipelines : name => value if name == "mcp" }

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value.execution_service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_storage_bucket_iam_member" "mcp_release_source" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_storage_bucket_iam_member" "mcp_release_source_read" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.mcp_build.email}"
}

resource "google_service_account_iam_member" "apply_acts_as_mcp_build" {
  service_account_id = google_service_account.mcp_build.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

resource "google_cloudbuild_trigger" "mcp_source" {
  for_each = local.mcp_builds

  project         = var.project_id
  location        = var.region
  name            = each.key
  description     = each.value.release ? "Test, audit, build, scan and release immutable private MCP source tags." : "Test, audit, build and scan the private MCP main branch without deployment."
  service_account = google_service_account.mcp_build.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.mcp_source.id
    push {
      branch = each.value.branch
      tag    = each.value.tag
    }
  }

  build {
    step {
      id         = "verify-mcp-source"
      name       = "golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36"
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        test -z "$$(gofmt -l cmd internal)" || {
          echo "Go sources are not formatted" >&2
          gofmt -d cmd internal
          exit 1
        }
        go mod download
        go mod verify
        go vet ./...
        go test -race -coverprofile=/workspace/mcp-cover.out ./...
        go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...
      EOT
      ]
    }

    step {
      id         = "checkout-public-platform"
      name       = "gcr.io/cloud-builders/git"
      entrypoint = "sh"
      args = ["-ceu", <<-EOT
        git clone --depth=1 --branch=main "${var.github_remote_uri}" /workspace/yourown-chat
      EOT
      ]
    }

    step {
      id         = "build-attested-mcp-images"
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "bash"
      env        = ["DOCKER_BUILDKIT=1"]
      args = ["-ceu", <<-EOT
        image_tag="git-$COMMIT_SHA"
        version="$$image_tag"
        if [ -n "$TAG_NAME" ]; then image_tag="$TAG_NAME"; version="$TAG_NAME"; fi

        build_date="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        docker buildx create --name mcp-cloudbuild --use || docker buildx use mcp-cloudbuild
        for server in google-cloud terraform-stacks; do
          image_path="${local.artifact_repository_prefix}/mcp-$$server"
          docker buildx build \
            --file "/workspace/yourown-chat/docker/mcp/Dockerfile" \
            --build-arg SERVICE="$$server" \
            --platform linux/amd64 \
            --label "org.opencontainers.image.source=${var.mcp_github_remote_uri}" \
            --label "org.opencontainers.image.revision=$COMMIT_SHA" \
            --label "org.opencontainers.image.version=$$version" \
            --label "org.opencontainers.image.created=$$build_date" \
            --tag "$$image_path:$$image_tag" \
            --attest=type=sbom \
            --attest=type=provenance,mode=max \
            --push .
        done
      EOT
      ]
    }

    step {
      id         = "scan-mcp-images"
      name       = local.scan_cli_image
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        image_tag="git-$COMMIT_SHA"
        if [ -n "$TAG_NAME" ]; then image_tag="$TAG_NAME"; fi
        for server in google-cloud terraform-stacks; do
          image_path="${local.artifact_repository_prefix}/mcp-$$server"
          digest="$$(gcloud artifacts docker images describe \
            "$$image_path:$$image_tag" --format='value(image_summary.digest)')"
          [ -n "$$digest" ] || { echo "Digest was not found for $$server" >&2; exit 1; }
          image="$$image_path@$$digest"
          scan="$$(gcloud artifacts docker images scan \
            "$$image" --remote --location=europe --format='value(response.scan)')"
          [ -n "$$scan" ] || { echo "On-Demand scan ID was not returned for $$server" >&2; exit 1; }
          gcloud artifacts docker images list-vulnerabilities "$$scan" \
            --format=json > "/workspace/$$server-vulnerabilities.json"
          gcloud artifacts docker images list-vulnerabilities "$$scan" \
            --format='value(vulnerability.effectiveSeverity)' > "/workspace/$$server-severities.txt"
          if grep -Exq 'CRITICAL|HIGH' "/workspace/$$server-severities.txt"; then
            echo "High or Critical vulnerability blocks MCP server $$server" >&2
            exit 1
          fi
          printf '%s' "$$digest" > "/workspace/$$server-image-digest"
          printf '%s' "$$image" > "/workspace/$$server-image-uri"
          printf '%s' "$$scan" > "/workspace/$$server-scan-id"
        done
        gcloud storage cp \
          /workspace/*-image-digest \
          /workspace/*-image-uri \
          /workspace/*-scan-id \
          /workspace/*-severities.txt \
          /workspace/*-vulnerabilities.json \
          /workspace/mcp-cover.out \
          go.mod go.sum \
          "gs://${google_storage_bucket.source.name}/evidence/yourown-chat-mcp/$BUILD_ID/"
      EOT
      ]
    }

    step {
      id         = "release-mcp"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        if [ -z "$TAG_NAME" ]; then
          echo "MCP branch verification completed; no release is created"
          exit 0
        fi
        if [ "${var.wrapper_releases_enabled}" = "true" ]; then
          echo "Legacy chart release path is superseded by the wrapper-release step"
          exit 0
        fi

        google_cloud_digest="$$(cat /workspace/google-cloud-image-digest)"
        terraform_stacks_digest="$$(cat /workspace/terraform-stacks-image-digest)"
        tunnel_repo="${local.artifact_repository_prefix}/mcp-cloudflared"
        tunnel_digest="$$(gcloud artifacts docker images describe \
          "$$tunnel_repo:runtime" --format='value(image_summary.digest)')"
        [ -n "$$tunnel_digest" ] || { echo "Pinned cloudflared runtime digest was not found" >&2; exit 1; }

        safe_tag="$$(printf '%s' "$TAG_NAME" | tr '.' '-')"
        build_suffix="$$(printf '%s' "$BUILD_ID" | cut -c1-8)"
        platform_sha="$$(git -C /workspace/yourown-chat rev-parse HEAD)"
        digest_set="$$(printf '%s\n%s\n%s\n' \
          "$$google_cloud_digest" "$$terraform_stacks_digest" "$$tunnel_digest" | sha256sum | cut -d' ' -f1)"

        gcloud deploy releases create "mcp-$$safe_tag-$SHORT_SHA-$$build_suffix" \
          --project "${var.project_id}" \
          --region "${var.region}" \
          --delivery-pipeline "mcp" \
          --source "/workspace/yourown-chat/helm" \
          --skaffold-file "skaffold-mcp.yaml" \
          --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
          --deploy-parameters "mcp_google_cloud_image=${local.mcp_image_paths.google_cloud}@$$google_cloud_digest,mcp_terraform_stacks_image=${local.mcp_image_paths.terraform_stacks}@$$terraform_stacks_digest,mcp_tunnel_image=$$tunnel_repo@$$tunnel_digest" \
          --annotations "source-repo=pilprod/yourown-chat-mcp,git-tag=$TAG_NAME,git-sha=$COMMIT_SHA,build-id=$BUILD_ID,image-set=$$digest_set,platform-sha=$$platform_sha"
      EOT
      ]
    }

    step {
      id         = "wrapper-release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = ["-ceu", <<-EOT
        if [ "${var.wrapper_releases_enabled}" != "true" ] || [ -z "$TAG_NAME" ]; then
          echo "Wrapper-based release path is disabled or this is not a release tag"
          exit 0
        fi

        platform_dir=/workspace/yourown-chat
        ${indent(8, local.helm_install_script)}
        ${indent(8, local.helm_registry_login_script)}

        tunnel_repo="${local.artifact_repository_prefix}/mcp-cloudflared"
        tunnel_digest="$$(gcloud artifacts docker images describe \
          "$$tunnel_repo:runtime" --format='value(image_summary.digest)')"
        [ -n "$$tunnel_digest" ] || { echo "Pinned cloudflared runtime digest was not found" >&2; exit 1; }
        image_args="--image mcp-cloudflared=$$tunnel_repo@$$tunnel_digest"
        for server in google-cloud terraform-stacks; do
          image_args="$$image_args --image mcp-$$server=$$(cat "/workspace/$$server-image-uri")"
        done
        platform_sha="$$(git -C /workspace/yourown-chat rev-parse HEAD)"

        bash /workspace/yourown-chat/helm/platform/release/assemble.sh \
          --repo "$$PWD" \
          --out /workspace/release-source \
          --evidence /workspace/release-evidence \
          --chart-registry "${local.chart_registry}" \
          ${join(" ", [for profile in local.wrapper_profiles.mcp : "--profile ${profile}"])} \
          ${local.wrapper_identity_args} \
          --secret-project "${var.project_id}" ${local.wrapper_dns_arg} \
          --source-revision "$COMMIT_SHA" \
          --platform-revision "$$platform_sha" \
          $$image_args

        safe_tag="$$(printf '%s' "$TAG_NAME" | tr '.' '-')"
        release_name="mcp-$$safe_tag"
        set +e
        output="$$(gcloud deploy releases create "$$release_name" \
          --project "${var.project_id}" \
          --region "${var.region}" \
          --delivery-pipeline "mcp" \
          --source /workspace/release-source \
          --gcs-source-staging-dir "gs://${google_storage_bucket.source.name}/source" \
          --deploy-parameters "$$(cat /workspace/release-source/deploy-parameters)" \
          --annotations "source-repo=pilprod/yourown-chat-mcp,git-tag=$TAG_NAME,git-sha=$COMMIT_SHA,build-id=$BUILD_ID,platform-sha=$$platform_sha,render=platform-wrapper" 2>&1)"
        status=$$?
        set -e
        if [ $$status -ne 0 ] && ! printf '%s' "$$output" | grep -q 'ALREADY_EXISTS'; then
          printf '%s\n' "$$output" >&2
          exit $$status
        fi
        printf '%s\n' "$$output"
        gcloud storage cp -r /workspace/release-evidence \
          "gs://${google_storage_bucket.source.name}/evidence/yourown-chat-mcp/$BUILD_ID/release/"
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
  }

  depends_on = [
    google_service_account_iam_member.apply_acts_as_mcp_build,
    google_project_iam_member.mcp_build_logs,
    google_project_iam_member.mcp_on_demand_scan,
    google_artifact_registry_repository_iam_member.mcp_writer,
    google_clouddeploy_delivery_pipeline_iam_member.mcp_source_releaser,
    google_project_iam_member.mcp_clouddeploy_viewer,
    google_service_account_iam_member.mcp_acts_as_exec,
    google_storage_bucket_iam_member.mcp_release_source,
    google_storage_bucket_iam_member.mcp_release_source_read,
  ]
}
