locals {
  # Shared out-of-band Cloud Build 2nd-gen connection (console OAuth, README.md).
  connection_id         = "projects/${var.project_id}/locations/${var.region}/connections/${var.connection_name}"
  image_repo_path       = "${var.artifact_registry_location}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repository_id}/${var.image_name}"
  rtcd_image_repo_path  = "${var.artifact_registry_location}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repository_id}/mattermost-rtcd"
  release_source_bucket = one(toset([for delivery in values(var.mattermost_deliveries) : delivery.source_bucket_name]))

  # Provenance and evidence identifiers are derived from the catalog-supplied
  # repository URLs; the module text itself names no repository.
  source_slug              = trimsuffix(trimprefix(var.github_remote_uri, "https://github.com/"), ".git")
  assembly_source_tree_url = "${trimsuffix(var.github_remote_uri, ".git")}/tree"
  web_source_tree_url      = "${trimsuffix(var.web_github_remote_uri, ".git")}/tree"
  server_source_tree_url   = "${trimsuffix(var.server_source_remote_uri, ".git")}/tree"

  scan_cli_image = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
}

# Preserve the existing production IAM objects while widening the module to
# two delivery destinations. These are address changes only; no permission is
# revoked and re-granted during the migration.
moved {
  from = google_clouddeploy_delivery_pipeline_iam_member.releaser
  to   = google_clouddeploy_delivery_pipeline_iam_member.releaser["production"]
}

moved {
  from = google_service_account_iam_member.build_acts_as_exec
  to   = google_service_account_iam_member.build_acts_as_exec["production"]
}

resource "google_cloudbuildv2_repository" "this" {
  project           = var.project_id
  location          = var.region
  name              = var.repository_name
  parent_connection = local.connection_id
  remote_uri        = var.github_remote_uri
}

# A v2 connection checks out only the triggering repository; Git does not
# inherit those credentials for private submodules. Link the private web source
# explicitly so the build can request a short-lived read token instead of
# storing a GitHub PAT or deploy key.
resource "google_cloudbuildv2_repository" "web_source" {
  project           = var.project_id
  location          = var.region
  name              = var.web_repository_name
  parent_connection = local.connection_id
  remote_uri        = var.web_github_remote_uri
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

resource "google_project_iam_custom_role" "source_reader" {
  project     = var.project_id
  role_id     = "mattermostSourceReader"
  title       = "Mattermost private source reader"
  description = "Mint short-lived read tokens for Cloud Build v2 repositories used by the Mattermost assembly."
  permissions = ["cloudbuild.repositories.accessReadToken"]
}

resource "google_project_iam_member" "build_source_reader" {
  project = var.project_id
  role    = google_project_iam_custom_role.source_reader.id
  member  = "serviceAccount:${google_service_account.build.email}"

  condition {
    title       = "mattermost_private_web_source_only"
    description = "The Mattermost build can mint a token only for its pinned private web source."
    expression  = "resource.name == '${google_cloudbuildv2_repository.web_source.id}'"
  }
}

resource "google_project_iam_member" "build_on_demand_scan" {
  project = var.project_id
  role    = "roles/ondemandscanning.admin"
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
  for_each = var.mattermost_deliveries

  project  = var.project_id
  location = var.region
  name     = each.value.pipeline_name
  role     = "roles/clouddeploy.releaser"
  member   = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "clouddeploy_viewer" {
  project = var.project_id
  role    = "roles/clouddeploy.viewer"
  member  = "serviceAccount:${google_service_account.build.email}"
}

resource "google_service_account_iam_member" "build_acts_as_exec" {
  for_each = var.mattermost_deliveries

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value.execution_service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.build.email}"
}

resource "google_storage_bucket_iam_member" "release_source" {
  bucket = local.release_source_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.build.email}"
}

resource "google_storage_bucket_iam_member" "release_source_bucket_read" {
  bucket = local.release_source_bucket
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

# --- Mattermost image entrypoints ------------------------------------------
resource "google_cloudbuild_trigger" "this" {
  for_each = var.builds

  project  = var.project_id
  location = var.region
  name     = "${each.key}-image"
  description = each.value.branch_regex != null ? (
    "Build + verify ${each.key} commits on branches matching ${each.value.branch_regex}; deploy to the dev-only pipeline."
    ) : (
    "Build + verify ${each.key} tags matching ${each.value.tag_regex}; deploy through the production release flow."
  )
  service_account = google_service_account.build.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.this.id
    push {
      branch = each.value.branch_regex
      tag    = each.value.tag_regex
    }
  }

  build {
    # No `images` block: buildx pushes from inside the step (--push); listing
    # images would trigger a second redundant push.

    step {
      id         = "initialize-product-sources"
      name       = local.scan_cli_image
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          # Initialize public source before any private credential exists.
          SOURCE_VERSION="$TAG_NAME" sh scripts/init-sources.sh server

          access_token="$$(gcloud auth print-access-token)"
          token_url="https://cloudbuild.googleapis.com/v2/${google_cloudbuildv2_repository.web_source.id}:accessReadToken"
          read_token="$$(python3 -c 'import json,sys,urllib.request; request=urllib.request.Request(sys.argv[1], data=b"{}", headers={"Authorization":"Bearer "+sys.argv[2], "Content-Type":"application/json"}, method="POST"); print(json.load(urllib.request.urlopen(request))["token"])' "$$token_url" "$$access_token")"
          [ -n "$$read_token" ] || {
            echo "Cloud Build returned an empty private-source read token" >&2
            exit 1
          }

          askpass="$$(mktemp /workspace/mattermost-git-askpass.XXXXXX)"
          trap 'rm -f "$$askpass"' EXIT
          printf '%s\n' \
            '#!/bin/sh' \
            'case "$$1" in' \
            '  *Username*) printf "%s\\n" x-access-token ;;' \
            '  *Password*) printf "%s\\n" "$$CLOUD_BUILD_REPO_TOKEN" ;;' \
            'esac' > "$$askpass"
          chmod 700 "$$askpass"
          CLOUD_BUILD_REPO_TOKEN="$$read_token" \
            GIT_ASKPASS="$$askpass" \
            GIT_TERMINAL_PROMPT=0 \
            SOURCE_VERSION="$TAG_NAME" sh scripts/init-sources.sh web
          unset access_token read_token
          rm -f "$$askpass"
          trap - EXIT

          assembly_sha="$$(git rev-parse HEAD)"
          server_sha="$$(git -C .sources/mattermost rev-parse HEAD)"
          web_sha="$$(git -C .sources/web rev-parse HEAD)"
          [ "$$assembly_sha" = "$COMMIT_SHA" ] || {
            echo "Cloud Build revision does not match the assembly checkout" >&2
            exit 1
          }
          for sha in "$$assembly_sha" "$$server_sha" "$$web_sha"; do
            printf '%s\n' "$$sha" | grep -Eq '^[0-9a-f]{40}$' || {
              echo "Product source is not pinned to a full lowercase Git SHA: $$sha" >&2
              exit 1
            }
          done
          printf 'ASSEMBLY_SHA=%s\nSERVER_SHA=%s\nWEB_SHA=%s\n' \
            "$$assembly_sha" "$$server_sha" "$$web_sha" \
            > /workspace/mattermost-source.env
        EOT
      ]
    }

    step {
      id   = "docker-build"
      name = "gcr.io/cloud-builders/docker"
      # buildx required: the Dockerfile uses RUN --mount=type=cache.
      env = [
        "DOCKER_BUILDKIT=1",
        "PIPELINE_BRANCH=$BRANCH_NAME",
        "PIPELINE_TAG=$TAG_NAME",
        "PIPELINE_SHORT_SHA=$SHORT_SHA",
        "PIPELINE_COMMIT_SHA=$COMMIT_SHA",
        "PIPELINE_BUILD_ID=$BUILD_ID",
      ]
      entrypoint = "bash"
      # Escaping: bash vars use the braceless $$VAR form (HCL passes `$$`
      # through, Cloud Build unescapes to `$`). Braced `$${VAR}` must not appear.
      args = [
        "-ceu",
        <<-EOT
          pipeline_branch="$$PIPELINE_BRANCH"
          pipeline_tag="$$PIPELINE_TAG"
          pipeline_short_sha="$$PIPELINE_SHORT_SHA"
          [ -n "$$pipeline_short_sha" ] || pipeline_short_sha="$$(printf '%s' "$$PIPELINE_COMMIT_SHA" | cut -c1-8)"
          if [ -n "$$pipeline_tag" ]; then
            pipeline_version="$$pipeline_tag"
            image_tag="$$pipeline_tag"
            moving_tag="latest"
          else
            [ -n "$$pipeline_branch" ] || pipeline_branch="manual"
            pipeline_version="$$pipeline_branch-$$pipeline_short_sha"
            image_tag="git-$$PIPELINE_COMMIT_SHA"
            moving_tag="$$pipeline_branch-latest"
          fi
          pipeline_build_date="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          . /workspace/mattermost-source.env

          docker buildx create --name cloudbuild --use || docker buildx use cloudbuild
          docker buildx build \
            --file=${var.dockerfile} \
            --cache-from=type=registry,ref="${local.image_repo_path}:buildcache" \
            --cache-to=type=registry,ref="${local.image_repo_path}:buildcache",mode=max \
            --no-cache-filter=server-builder,runtime \
            --build-arg BUILD_NUMBER="$$pipeline_version" \
            --build-arg BUILD_HASH="$$SERVER_SHA" \
            --build-arg BUILD_DATE="$$pipeline_build_date" \
            --build-arg SOURCE_URL="${local.server_source_tree_url}/$$SERVER_SHA" \
            --build-arg WEB_BUILD_HASH="$$WEB_SHA" \
            --build-arg WEB_SOURCE_URL="${local.web_source_tree_url}/$$WEB_SHA" \
            --build-arg ASSEMBLY_BUILD_HASH="$$ASSEMBLY_SHA" \
            --build-arg ASSEMBLY_SOURCE_URL="${local.assembly_source_tree_url}/$$ASSEMBLY_SHA" \
            --tag "${local.image_repo_path}:$$image_tag" \
            --tag "${local.image_repo_path}:$$moving_tag" \
            --attest=type=sbom \
            --attest=type=provenance,mode=max \
            --push \
            .
        EOT
      ]
    }

    # Verify the artifact that was actually pushed, not an intermediate local
    # stage. This binds the binary, OCI metadata, source offer and mandatory
    # notices to one immutable source revision before Cloud Deploy exists.
    step {
      id         = "verify-product-image"
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "sh"
      args = [
        "-ceu",
        <<-EOT
          . /workspace/mattermost-source.env
          if [ -n "$TAG_NAME" ]; then
            image="${local.image_repo_path}:$TAG_NAME"
            pipeline_version="$TAG_NAME"
          else
            image="${local.image_repo_path}:git-$COMMIT_SHA"
            pipeline_version="$BRANCH_NAME-$SHORT_SHA"
          fi
          server_url="${local.server_source_tree_url}/$$SERVER_SHA"
          web_url="${local.web_source_tree_url}/$$WEB_SHA"
          assembly_url="${local.assembly_source_tree_url}/$$ASSEMBLY_SHA"
          docker pull "$$image"
          sh scripts/verify-product-image.sh \
            "$$image" \
            "$$pipeline_version" \
            "$$SERVER_SHA" \
            "$$server_url" \
            "$$WEB_SHA" \
            "$$web_url" \
            "$$ASSEMBLY_SHA" \
            "$$assembly_url"
        EOT
      ]
    }

    step {
      id         = "scan-product-image"
      name       = local.scan_cli_image
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          . /workspace/mattermost-source.env
          if [ -n "$TAG_NAME" ]; then image_tag="$TAG_NAME"; else image_tag="git-$COMMIT_SHA"; fi
          image_path="${local.image_repo_path}"
          digest="$$(gcloud artifacts docker images describe \
            "$$image_path:$$image_tag" --format='value(image_summary.digest)')"
          [ -n "$$digest" ] || { echo "Mattermost image digest was not found" >&2; exit 1; }
          image="$$image_path@$$digest"
          scan="$$(gcloud artifacts docker images scan \
            "$$image" --remote --location=europe --format='value(response.scan)')"
          [ -n "$$scan" ] || { echo "On-Demand scan ID was not returned" >&2; exit 1; }
          gcloud artifacts docker images list-vulnerabilities "$$scan" \
            --format=json > /workspace/mattermost-vulnerabilities.json
          gcloud artifacts docker images list-vulnerabilities "$$scan" \
            --format='value(vulnerability.effectiveSeverity)' > /workspace/mattermost-severities.txt
          if grep -Exq 'CRITICAL|HIGH' /workspace/mattermost-severities.txt; then
            echo "High or Critical vulnerability blocks the Mattermost image" >&2
            exit 1
          fi
          printf '%s' "$$digest" > /workspace/mattermost-image-digest
          printf '%s' "$$image" > /workspace/mattermost-image-uri
          printf '%s' "$$scan" > /workspace/mattermost-scan-id
          gcloud storage cp \
            /workspace/mattermost-image-digest \
            /workspace/mattermost-image-uri \
            /workspace/mattermost-scan-id \
            /workspace/mattermost-severities.txt \
            /workspace/mattermost-vulnerabilities.json \
            /workspace/mattermost-source.env \
            "gs://${local.release_source_bucket}/evidence/${var.repository_name}/$BUILD_ID/"
        EOT
      ]
    }

    step {
      id   = "checkout-deploy-source"
      name = "gcr.io/cloud-builders/git"
      args = [
        "clone",
        "--depth=1",
        "--branch=${var.mattermost_deliveries[each.value.delivery].deploy_repository_ref}",
        var.mattermost_deliveries[each.value.delivery].deploy_repository_uri,
        "/workspace/yourown-chat",
      ]
    }

    # Only after image push and compliance verification do we freeze its
    # digest and create Cloud Deploy state. The selected destination is static:
    # Release branches and prerelease tags go to the dev-only pipeline; stable
    # semver tags go through dev -> approval -> prod.
    step {
      id         = "mattermost-release"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          . /workspace/mattermost-source.env
          if [ -n "$TAG_NAME" ]; then
            image="${local.image_repo_path}:$TAG_NAME"
            source_ref="$TAG_NAME"
            pipeline_version="$TAG_NAME"
          else
            image="${local.image_repo_path}:git-$COMMIT_SHA"
            source_ref="$BRANCH_NAME"
            pipeline_version="$BRANCH_NAME-$SHORT_SHA"
          fi
          digest="$$(gcloud artifacts docker images describe "$$image" --format='value(image_summary.digest)')"
          deploy_parameters="$$(bash \
            /workspace/yourown-chat/helm/mattermost-image-parameters.sh \
            "${local.image_repo_path}" \
            "$$digest")"
          . /workspace/yourown-chat/helm/mattermost/rtcd/source.lock
          rtcd_digest="$$(gcloud artifacts docker images describe \
            "${local.rtcd_image_repo_path}:$$RTCD_SOURCE_COMMIT" \
            --format='value(image_summary.digest)')"
          [ -n "$$rtcd_digest" ] || {
            echo "Pinned RTCD image digest was not found for $$RTCD_SOURCE_COMMIT" >&2
            exit 1
          }
          deploy_parameters="$$deploy_parameters,mattermost_rtcd_image=${local.rtcd_image_repo_path}@$$rtcd_digest"

          # Include both the source commit and this build when the derived
          # production rollout stays within Cloud Deploy's 63-character limit.
          # The build suffix is optional; the source commit is never dropped.
          release_id="$$(bash \
            /workspace/yourown-chat/helm/mattermost-release-id.sh \
            "$$source_ref" \
            "$COMMIT_SHA" \
            "$BUILD_ID" \
            "${var.mattermost_deliveries[each.value.delivery].initial_target_name}")"

          # Chart.appVersion describes the exact immutable image promoted by
          # this release. The deploy repository keeps a neutral placeholder;
          # mutate only the frozen Cloud Deploy source checkout.
          sed -E -i.bak \
            "s|^appVersion:.*$$|appVersion: \"$$pipeline_version\"|" \
            /workspace/yourown-chat/helm/mattermost/Chart.yaml
          rm -f /workspace/yourown-chat/helm/mattermost/Chart.yaml.bak

          gcloud deploy releases create "$$release_id" \
            --project "${var.project_id}" \
            --region "${var.region}" \
            --delivery-pipeline "${var.mattermost_deliveries[each.value.delivery].pipeline_name}" \
            --source "/workspace/yourown-chat/helm" \
            --skaffold-file "skaffold-mattermost.yaml" \
            --gcs-source-staging-dir "gs://${var.mattermost_deliveries[each.value.delivery].source_bucket_name}/source" \
            --deploy-parameters "$$deploy_parameters" \
            --annotations "source-repo=${local.source_slug},source-ref=$$source_ref,source-branch=$BRANCH_NAME,git-tag=$TAG_NAME,assembly-sha=$$ASSEMBLY_SHA,server-sha=$$SERVER_SHA,web-sha=$$WEB_SHA,build-id=$BUILD_ID,image-digest=$$digest,rtcd-image-digest=$$rtcd_digest,rtcd-source=$$RTCD_SOURCE_COMMIT,rtcd-security-build=$$RTCD_BUILD_VERSION,release-channel=${each.value.release_channel}"
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
    google_project_iam_member.build_source_reader,
    google_project_iam_member.build_on_demand_scan,
    google_artifact_registry_repository_iam_member.writer,
    google_clouddeploy_delivery_pipeline_iam_member.releaser,
    google_project_iam_member.clouddeploy_viewer,
    google_service_account_iam_member.build_acts_as_exec,
    google_storage_bucket_iam_member.release_source,
    google_storage_bucket_iam_member.release_source_bucket_read,
  ]
}
