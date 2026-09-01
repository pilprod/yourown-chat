locals {
  count                      = var.enabled ? 1 : 0
  registry_host              = "${var.artifact_registry_location}-docker.pkg.dev"
  artifact_repository_prefix = "${local.registry_host}/${var.project_id}/${var.artifact_registry_repository_id}/kagent"
  staging_repository_prefix  = "${local.registry_host}/${var.project_id}/${var.staging_registry_repository_id}/kagent"
  publication_driver_base64  = base64encode(file("${path.module}/scripts/publish-artifact-registry.sh"))
  publication_driver_sha256  = filesha256("${path.module}/scripts/publish-artifact-registry.sh")
  publication_driver_chunks = [
    for index in range(ceil(length(local.publication_driver_base64) / 8000)) :
    substr(local.publication_driver_base64, index * 8000, 8000)
  ]
  scan_policy_evaluator_base64 = base64encode(file("${path.module}/scripts/evaluate-scan-vulnerabilities.sh"))
  scan_policy_evaluator_sha256 = filesha256("${path.module}/scripts/evaluate-scan-vulnerabilities.sh")
  scan_policy_evaluator_chunks = [
    for index in range(ceil(length(local.scan_policy_evaluator_base64) / 8000)) :
    substr(local.scan_policy_evaluator_base64, index * 8000, 8000)
  ]
  trusted_jq_index       = "ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486"
  trusted_jq_amd64_image = "ghcr.io/jqlang/jq@sha256:1e7ad54d387c3ee4cb921f8a9de0d7f2359b375f04a37d10255fda4cd119029a"
  trusted_jq_amd64_layer = "sha256:45f05cf73251ac39adec8657aba8dc90b26a9aa53ccb34323f2fb6929eb0fc74"
  trusted_jq_sha256      = "b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"
  publication_environment = [
    "KAGENT_ARTIFACT_PREFIX=${local.artifact_repository_prefix}",
    "KAGENT_EVIDENCE_BUCKET=${var.evidence_bucket_name}",
    "KAGENT_EXPECTED_BUILD_ID=$BUILD_ID",
    "KAGENT_EXPECTED_PROJECT_ID=${var.project_id}",
    "KAGENT_EXPECTED_SOURCE_COMMIT=${var.source_commit}",
    "KAGENT_EXPECTED_SOURCE_TAG=$_RELEASE_TAG",
    "KAGENT_PUBLICATION_DRIVER_SHA256=${local.publication_driver_sha256}",
    "KAGENT_REGISTRY_HOST=${local.registry_host}",
    "KAGENT_SCAN_POLICY_EVALUATOR_SHA256=${local.scan_policy_evaluator_sha256}",
    "KAGENT_STAGING_PREFIX=${local.staging_repository_prefix}",
    "KAGENT_TRUSTED_JQ_SHA256=${local.trusted_jq_sha256}",
  ]
  submitter_members = var.enabled ? setunion(
    toset(["serviceAccount:${var.apply_service_account_email}"]),
    var.submitter_members,
  ) : toset([])
}

resource "google_service_account" "publisher" {
  count = local.count

  project      = var.project_id
  account_id   = "kagent-preview-publisher"
  display_name = "kagent fork preview publisher"
  description  = "Publishes reviewed kagent fork preview images and charts and writes immutable release evidence."
}

resource "google_project_iam_member" "log_writer" {
  count = local.count

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.publisher[0].email}"
}

# Passing release artifacts land in the dedicated private immutable repository.
# No writer permission is granted on the shared Mattermost/application repo.
resource "google_artifact_registry_repository_iam_member" "release_writer" {
  count = local.count

  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.publisher[0].email}"
}


# Candidate image refs remain private and disposable until On-Demand Scanning
# succeeds. platform-gcp applies a bounded cleanup policy to this repository.
resource "google_artifact_registry_repository_iam_member" "staging_writer" {
  count = local.count

  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.staging_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.publisher[0].email}"
}

resource "google_project_iam_member" "scanner" {
  count = local.count

  project = var.project_id
  role    = "roles/ondemandscanning.admin"
  member  = "serviceAccount:${google_service_account.publisher[0].email}"
}

# Cloud Build requires the configured trigger identity to create the build.
# The trigger explicitly names the publisher service account and selects Cloud
# Logging, so it does not rely on either default build service account.
resource "google_project_iam_custom_role" "build_invoker" {
  count = local.count

  project     = var.project_id
  role_id     = "kagentPreviewBuildInvoker"
  title       = "kagent preview build invoker"
  description = "Allows only the kagent preview trigger identity to create its Cloud Build invocation."
  permissions = ["cloudbuild.builds.create"]
  stage       = "GA"
}

resource "google_project_iam_member" "build_invoker" {
  count = local.count

  project = var.project_id
  role    = google_project_iam_custom_role.build_invoker[0].id
  member  = "serviceAccount:${google_service_account.publisher[0].email}"
}

resource "google_storage_bucket" "evidence" {
  count = local.count

  project                     = var.project_id
  name                        = var.evidence_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = var.labels

  versioning {
    enabled = true
  }

  retention_policy {
    retention_period = var.evidence_retention_seconds
    is_locked        = false
  }

  dynamic "encryption" {
    for_each = var.kms_key_name == null ? [] : [var.kms_key_name]
    content {
      default_kms_key_name = encryption.value
    }
  }
}

resource "google_storage_bucket_iam_member" "evidence_creator" {
  count = local.count

  bucket = google_storage_bucket.evidence[0].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.publisher[0].email}"
}

# Source verification reads the generation-qualified private Substrate receipt
# and publication verifies its own immutable kagent lock/receipt generations.
# The identity cannot mutate or delete any existing object.
resource "google_storage_bucket_iam_member" "evidence_viewer" {
  count = local.count

  bucket = google_storage_bucket.evidence[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.publisher[0].email}"

  condition {
    title       = "substrate-input-and-kagent-output-read"
    description = "Read the exact private Substrate handoff and immutable kagent release evidence owned by this rail."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.evidence[0].name}/objects/substrate/0.0.22-private.3/\") || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.evidence[0].name}/objects/kagent/\")"
  }
}

# Legacy empty container retained only so adopting the Artifact Registry build
# path does not mix a destructive secret deletion into the release change. The
# trigger below has no secret injection and never reads this resource.
resource "google_secret_manager_secret" "ghcr_write" {
  count = local.count

  project   = var.project_id
  secret_id = var.ghcr_secret_id
  labels    = var.labels

  replication {
    user_managed {
      replicas {
        location = var.region

        dynamic "customer_managed_encryption" {
          for_each = var.kms_key_name == null ? [] : [var.kms_key_name]
          content {
            kms_key_name = customer_managed_encryption.value
          }
        }
      }
    }
  }
}

# Preserve the pre-existing keyed state address for the Terraform apply
# identity. Changing this identical IAM tuple to a count-based address would
# plan create/delete and could revoke the grant after recording the new object.
# Release submitters remain excluded: they can only publish to the dedicated
# request topic below.
resource "google_service_account_iam_member" "submitter" {
  for_each = var.enabled ? toset(["serviceAccount:${var.apply_service_account_email}"]) : toset([])

  service_account_id = google_service_account.publisher[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

# The trigger executes as the publisher and can act as no other service
# account. Its explicit service_account and logging settings keep build
# execution independent of the legacy and Compute Engine default accounts.
resource "google_service_account_iam_member" "publisher_acts_as_self" {
  count = local.count

  service_account_id = google_service_account.publisher[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.publisher[0].email}"
}

# Terraform creates and owns the release topic and its IAM policy. A dedicated
# role keeps that authority narrower than roles/pubsub.editor while including
# the get/setIamPolicy permissions that the topic IAM member resource requires.
resource "google_project_iam_custom_role" "apply_pubsub_manager" {
  count = local.count

  project     = var.project_id
  role_id     = "kagentPreviewPubsubManager"
  title       = "kagent preview Pub/Sub manager"
  description = "Allows Terraform to manage only the kagent preview release topic and its IAM policy."
  permissions = [
    "pubsub.topics.create",
    "pubsub.topics.delete",
    "pubsub.topics.get",
    "pubsub.topics.getIamPolicy",
    "pubsub.topics.list",
    "pubsub.topics.setIamPolicy",
    "pubsub.topics.update",
  ]
  stage = "GA"
}

resource "google_project_iam_member" "apply_pubsub_manager" {
  count = local.count

  project = var.project_id
  role    = google_project_iam_custom_role.apply_pubsub_manager[0].id
  member  = "serviceAccount:${var.apply_service_account_email}"
}

# google provider 6.x requires every BuildTrigger to declare an event/source.
# A dedicated Pub/Sub topic supplies that event without a GitHub connection or
# shared webhook credential. IAM on this exact topic is the release-submit
# boundary; the build independently validates the annotated tag and commit.
resource "google_pubsub_topic" "release_request" {
  count = local.count

  project = var.project_id
  name    = "kagent-preview-release"
  labels  = var.labels

  depends_on = [google_project_iam_member.apply_pubsub_manager]
}

resource "google_pubsub_topic_iam_member" "release_submitter" {
  for_each = local.submitter_members

  project = var.project_id
  topic   = google_pubsub_topic.release_request[0].name
  role    = "roles/pubsub.publisher"
  member  = each.value
}

# An annotated immutable source tag and an IAM-authenticated Pub/Sub message are
# the release request. The build clones the public fork itself, so no Cloud
# Build GitHub connection, GitHub OAuth authorizer or Actions runner is needed.
resource "google_cloudbuild_trigger" "release" {
  count = local.count

  project         = var.project_id
  location        = var.region
  name            = "kagent-preview-release"
  description     = "Build reviewed kagent fork previews into Google Artifact Registry and write immutable GCS evidence."
  service_account = google_service_account.publisher[0].id

  pubsub_config {
    topic = google_pubsub_topic.release_request[0].id
  }

  substitutions = {
    _RELEASE_TAG = "$(body.message.attributes.releaseTag)"
  }

  filter = "_RELEASE_TAG != \"\""

  build {
    timeout = var.build_timeout

    step {
      id         = "checkout-reviewed-source"
      name       = "gcr.io/cloud-builders/git@sha256:bfcbd8719280b196bd860e89531c3c9b598daab4a07aef1d17a163c822d569bd"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          set -o pipefail
          tag="$_RELEASE_TAG"
          printf '%s\n' "$$tag" | grep -Eq '${var.release_tag_regex}'

          git clone --filter=blob:none --no-tags \
            "${var.github_remote_uri}" /workspace/source
          cd /workspace/source
          git fetch --force origin \
            refs/heads/yourown-chat:refs/remotes/origin/yourown-chat
          git fetch --force origin \
            "refs/tags/$$tag:refs/tags/$$tag"
          test "$$(git cat-file -t "refs/tags/$$tag")" = tag
          tag_commit="$$(git rev-parse "refs/tags/$$tag^{}")"
          test "$$tag_commit" = "${var.source_commit}"
          git checkout --detach "${var.source_commit}"
          git merge-base --is-ancestor \
            "${var.source_commit}" origin/yourown-chat
          test -z "$$(git status --porcelain)"

          version="$$(printf '%s' "$$tag" | sed 's/^gcp-v//')"
          build_date="$$(git show -s --format=%cs HEAD)"
          [[ "$$build_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$$ ]]
          printf '%s' "$$version" > /workspace/kagent-release-version
          printf '%s' "$$tag" > /workspace/kagent-source-tag
          printf '%s' "${var.source_commit}" > /workspace/kagent-source-commit
          printf '%s' "$BUILD_ID" > /workspace/kagent-build-id
          printf '%s' "$$build_date" > /workspace/kagent-build-date
        EOT
      ]
    }

    # The exact Google Cloud SDK image intentionally does not install jq.
    # Extract the official statically linked amd64 jq binary from its pinned
    # multi-arch index and bind its bytes before any trusted driver action.
    # Every driver invocation rechecks this Terraform-pinned digest.
    step {
      id         = "materialize-pinned-json-parser"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          parser_dir=/workspace/trusted-bin
          parser="$$parser_dir/jq"
          parser_stage="$$(mktemp -d /workspace/.jq-stage.XXXXXX)"
          index_manifest="$$(mktemp /workspace/.jq-index.XXXXXX)"
          child_manifest="$$(mktemp /workspace/.jq-child.XXXXXX)"
          container=''
          cleanup() {
            rm -f "$$parser_stage/jq"
            rmdir "$$parser_stage" >/dev/null 2>&1 || true
            rm -f "$$index_manifest" "$$child_manifest"
            if [[ -n "$$container" ]]; then
              docker rm -f "$$container" >/dev/null 2>&1 || true
            fi
          }
          trap cleanup EXIT
          install -d -m 0755 "$$parser_dir"
          [[ -d "$$parser_dir" && ! -L "$$parser_dir" ]]
          test ! -e "$$parser"
          # The index, selected linux/amd64 child, rootfs layer and final /jq
          # bytes are all pinned independently in Terraform.
          test '${local.trusted_jq_index}' = 'ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486'
          test '${local.trusted_jq_amd64_layer}' = 'sha256:45f05cf73251ac39adec8657aba8dc90b26a9aa53ccb34323f2fb6929eb0fc74'
          docker pull --platform linux/amd64 '${local.trusted_jq_amd64_image}' >/dev/null
          container="$$(docker create --platform linux/amd64 '${local.trusted_jq_amd64_image}')"
          docker cp "$$container:/jq" "$$parser_stage/jq"
          printf '%s  %s\n' '${local.trusted_jq_sha256}' "$$parser_stage/jq" \
            | sha256sum --check --status
          chmod 0555 "$$parser_stage/jq"
          docker buildx imagetools inspect --raw '${local.trusted_jq_index}' > "$$index_manifest"
          "$$parser_stage/jq" -e \
            --arg child 'sha256:1e7ad54d387c3ee4cb921f8a9de0d7f2359b375f04a37d10255fda4cd119029a' '
              [
                .manifests[]
                | select(.platform.os == "linux" and .platform.architecture == "amd64")
                | .digest
              ] == [$$child]
            ' "$$index_manifest" >/dev/null
          docker buildx imagetools inspect --raw '${local.trusted_jq_amd64_image}' > "$$child_manifest"
          "$$parser_stage/jq" -e \
            --arg layer '${local.trusted_jq_amd64_layer}' '
              any(.layers[]; .digest == $$layer)
            ' "$$child_manifest" >/dev/null
          mv -f "$$parser_stage/jq" "$$parser"
          rmdir "$$parser_stage"
          rm -f "$$index_manifest" "$$child_manifest"
          docker rm -f "$$container" >/dev/null
          container=''
          trap - EXIT
        EOT
      ]
    }

    # Fail before the multi-architecture build if the exact Cloud SDK image
    # cannot execute the independently pinned parser or Python stdlib used by
    # the trusted scanner/evidence actions. Docker must remain absent here.
    step {
      id         = "verify-pinned-cloud-sdk-tool-contract"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          parser=/workspace/trusted-bin/jq
          [[ -f "$$parser" && ! -L "$$parser" && -x "$$parser" ]]
          printf '%s  %s\n' '${local.trusted_jq_sha256}' "$$parser" \
            | sha256sum --check --status
          test "$$($$parser --version)" = 'jq-1.8.2'
          test -x /usr/bin/python3
          /usr/bin/python3 -c 'import json; assert json.loads("{}") == {}'
          for tool in awk base64 chmod cmp cut grep mktemp mv sed sha256sum sort tr wc; do
            command -v "$$tool" >/dev/null
          done
          test "$$(type -t mapfile)" = builtin
          if command -v docker >/dev/null 2>&1; then
            printf 'Docker unexpectedly present in pinned Cloud SDK scanner image\n' >&2
            exit 1
          fi
          gcloud version >/dev/null
        EOT
      ]
    }

    step {
      id         = "materialize-release-driver"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      args = concat(
        [
          "-ceu",
          <<-EOT
            output=/workspace/publish-kagent-artifact-registry.sh
            printf '%s' "$$@" | base64 -d > "$$output"
            printf '%s  %s\n' '${local.publication_driver_sha256}' "$$output" \
              | sha256sum --check --status
            chmod 0555 "$$output"
          EOT
          ,
          "materialize-release-driver",
        ],
        local.publication_driver_chunks,
      )
    }

    step {
      id   = "build-pinned-release-toolbox"
      name = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      args = [
        "build",
        "--pull",
        "--tag",
        "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID",
        "--file",
        "/workspace/source/.github/cloud-build/fork-preview-tools.Dockerfile",
        "/workspace/source",
      ]
    }

    step {
      id         = "reject-existing-final-refs"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "reject-existing"]
    }

    step {
      id         = "materialize-private-substrate-verification-inputs"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          receipt_uri='${var.substrate_release_evidence_uri}'
          test -n "$$receipt_uri"
          case "$$receipt_uri" in
            'gs://${var.evidence_bucket_name}/substrate/0.0.22-private.3/release-evidence.json#'[1-9][0-9]*) ;;
            *)
              printf 'private Substrate evidence URI is not the applied generation-qualified coordinate\n' >&2
              exit 1
              ;;
          esac

          install -d -m 0700 /workspace/private-substrate
          gcloud storage cp "$$receipt_uri" \
            /workspace/private-substrate/release-evidence.json
          chmod 0400 /workspace/private-substrate/release-evidence.json

          registry_auth="$$(printf '%s' \
            "oauth2accesstoken:$$(gcloud auth print-access-token)" | base64 | tr -d '\n')"
          printf '{"auths":{"%s":{"auth":"%s"}}}\n' \
            '${local.registry_host}' "$$registry_auth" \
            > /workspace/private-substrate/registry-config.json
          chmod 0400 /workspace/private-substrate/registry-config.json
        EOT
      ]
    }

    step {
      id         = "verify-release-source"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          cleanup() {
            rm -f \
              /workspace/private-substrate/registry-config.json \
              /workspace/private-substrate/release-evidence.json
          }
          trap cleanup EXIT
          docker run --rm \
            --volume /workspace:/workspace \
            --volume /workspace/trusted-bin:/workspace/trusted-bin:ro \
            --workdir /workspace/source \
            --env SUBSTRATE_RELEASE_EVIDENCE=/workspace/private-substrate/release-evidence.json \
            --env SUBSTRATE_RELEASE_EVIDENCE_URI='${var.substrate_release_evidence_uri}' \
            --env HELM_REGISTRY_CONFIG=/workspace/private-substrate/registry-config.json \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/source/scripts/verify-cloud-build-fork-preview-source.sh \
            "$$(< /workspace/kagent-release-version)" \
            "${var.source_commit}"
        EOT
      ]
    }

    # Run every source-owned chart/plugin action before trusted image digest
    # evidence is recorded. A pinned git step then proves the source checkout
    # still matches the reviewed commit before any candidate image is built.
    step {
      id         = "package-and-reproduce-charts"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          docker run --rm \
            --volume /workspace:/workspace \
            --volume /workspace/trusted-bin:/workspace/trusted-bin:ro \
            --workdir /workspace/source \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/source/scripts/cloud-build-fork-preview-charts.sh \
            package "$$(< /workspace/kagent-release-version)"
        EOT
      ]
    }

    step {
      id         = "reverify-reviewed-source-after-packaging"
      name       = "gcr.io/cloud-builders/git@sha256:bfcbd8719280b196bd860e89531c3c9b598daab4a07aef1d17a163c822d569bd"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          cd /workspace/source
          test "$$(git rev-parse HEAD)" = "${var.source_commit}"
          test -z "$$(git status --porcelain)"
          test "$$(< /workspace/kagent-source-commit)" = "${var.source_commit}"
          test "$$(< /workspace/kagent-source-tag)" = "$_RELEASE_TAG"
          test "$$(< /workspace/kagent-build-id)" = "$BUILD_ID"
          version="$$(printf '%s' "$_RELEASE_TAG" | sed 's/^gcp-v//')"
          test "$$(< /workspace/kagent-release-version)" = "$$version"
          test ! -e /workspace/release-inputs
          test ! -e /workspace/release
          [[ -d /workspace/chart-dist && ! -L /workspace/chart-dist ]]
          [[ -d /workspace/chart-dist-reproducibility-check && ! -L /workspace/chart-dist-reproducibility-check ]]
        EOT
      ]
    }

    step {
      id   = "install-multiarch-emulation"
      name = "docker.io/tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0"
      args = ["--install", "all"]
    }

    step {
      id         = "build-candidate-images"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = concat(local.publication_environment, ["BUILDX_NO_DEFAULT_ATTESTATIONS=1"])
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "build-images"]
    }

    step {
      id         = "record-buildkit-image-digests"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args = [
        "-ceu",
        <<-EOT
          docker run --rm \
            --volume /workspace:/workspace \
            --volume /workspace/trusted-bin:/workspace/trusted-bin:ro \
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_PUBLICATION_DRIVER_SHA256 \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_SCAN_POLICY_EVALUATOR_SHA256 \
            --env KAGENT_STAGING_PREFIX \
            --env KAGENT_TRUSTED_JQ_SHA256 \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/publish-kagent-artifact-registry.sh record-images
        EOT
      ]
    }

    step {
      id         = "verify-candidate-image-indexes"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "verify-candidates"]
    }

    step {
      id         = "record-candidate-platform-digests"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args = [
        "-ceu",
        <<-EOT
          docker run --rm \
            --volume /workspace:/workspace \
            --volume /workspace/trusted-bin:/workspace/trusted-bin:ro \
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_PUBLICATION_DRIVER_SHA256 \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_SCAN_POLICY_EVALUATOR_SHA256 \
            --env KAGENT_STAGING_PREFIX \
            --env KAGENT_TRUSTED_JQ_SHA256 \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/publish-kagent-artifact-registry.sh record-platforms
        EOT
      ]
    }

    # Re-read every immutable staging index and bind both recorded platform
    # children immediately before scanning. The driver is reconstructed from
    # Terraform-owned chunks and verified inside the pinned Docker builder;
    # the source-built toolbox is not trusted for this final binding.
    step {
      id         = "reverify-platform-bindings-before-scan"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args = concat(
        [
          "-ceu",
          <<-EOT
            driver=/workspace/publish-kagent-artifact-registry.sh
            driver_tmp="$$(mktemp /workspace/.publish-kagent-pre-scan.XXXXXX)"
            trap 'rm -f "$$driver_tmp"' EXIT
            printf '%s' "$$@" | base64 -d > "$$driver_tmp"
            printf '%s  %s\n' '${local.publication_driver_sha256}' "$$driver_tmp" \
              | sha256sum --check --status
            chmod 0555 "$$driver_tmp"
            mv -f "$$driver_tmp" "$$driver"
            trap - EXIT
            exec "$$driver" verify-platform-bindings
          EOT
          ,
          "reverify-platform-bindings-before-scan",
        ],
        local.publication_driver_chunks,
      )
    }

    # The scanner image intentionally has no Docker CLI. It scans only the
    # immutable child digest refs bound by the immediately preceding step.
    step {
      id         = "scan-candidate-images"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args = concat(
        [
          "-ceu",
          <<-EOT
            driver=/workspace/publish-kagent-artifact-registry.sh
            evaluator=/workspace/evaluate-kagent-scan-vulnerabilities.sh
            driver_tmp="$$(mktemp /workspace/.publish-kagent.XXXXXX)"
            evaluator_tmp="$$(mktemp /workspace/.evaluate-kagent-scan.XXXXXX)"
            trap 'rm -f "$$driver_tmp" "$$evaluator_tmp"' EXIT
            driver_chunk_count="$$1"
            shift
            [[ "$$driver_chunk_count" =~ ^[1-9][0-9]*$$ ]]
            driver_chunks=("$$${@:1:driver_chunk_count}")
            shift "$$driver_chunk_count"
            printf '%s' "$$${driver_chunks[@]}" | base64 -d > "$$driver_tmp"
            printf '%s' "$$@" | base64 -d > "$$evaluator_tmp"
            printf '%s  %s\n' '${local.publication_driver_sha256}' "$$driver_tmp" \
              | sha256sum --check --status
            printf '%s  %s\n' '${local.scan_policy_evaluator_sha256}' "$$evaluator_tmp" \
              | sha256sum --check --status
            chmod 0555 "$$driver_tmp" "$$evaluator_tmp"
            mv -f "$$driver_tmp" "$$driver"
            mv -f "$$evaluator_tmp" "$$evaluator"
            trap - EXIT
            exec "$$driver" scan-images
          EOT
          ,
          "scan-candidate-images",
          tostring(length(local.publication_driver_chunks)),
        ],
        local.publication_driver_chunks,
        local.scan_policy_evaluator_chunks,
      )
    }

    # A generation-zero object serializes publication of one immutable version.
    # If a build fails after taking the lock, that version remains deliberately
    # unusable and the next reviewed release must use a new tag.
    step {
      id         = "acquire-immutable-release-lock"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "acquire-lock"]
    }

    step {
      id         = "recheck-final-refs"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "reject-existing"]
    }

    step {
      id         = "promote-final-image-aliases"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "promote-images"]
    }

    step {
      id         = "publish-final-charts"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args = [
        "-ceu",
        <<-EOT
          docker run --rm \
            --network cloudbuild \
            --volume /workspace:/workspace \
            --volume /workspace/trusted-bin:/workspace/trusted-bin:ro \
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_PUBLICATION_DRIVER_SHA256 \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_SCAN_POLICY_EVALUATOR_SHA256 \
            --env KAGENT_STAGING_PREFIX \
            --env KAGENT_TRUSTED_JQ_SHA256 \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/publish-kagent-artifact-registry.sh publish-charts
        EOT
      ]
    }

    step {
      id         = "verify-all-final-registry-digests"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "verify-finals"]
    }

    step {
      id         = "assemble-deployment-evidence"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args = [
        "-ceu",
        <<-EOT
          docker run --rm \
            --network cloudbuild \
            --volume /workspace:/workspace \
            --volume /workspace/trusted-bin:/workspace/trusted-bin:ro \
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_EVIDENCE_BUCKET \
            --env KAGENT_PUBLICATION_DRIVER_SHA256 \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_SCAN_POLICY_EVALUATOR_SHA256 \
            --env KAGENT_STAGING_PREFIX \
            --env KAGENT_TRUSTED_JQ_SHA256 \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/publish-kagent-artifact-registry.sh assemble-evidence
        EOT
      ]
    }

    # The source-built toolbox had writable workspace access while assembling
    # evidence. Re-materialize the Terraform-pinned driver in a pinned Docker
    # builder and re-read every staging index before trusting that evidence.
    step {
      id         = "reverify-platform-bindings-after-assembly"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args = concat(
        [
          "-ceu",
          <<-EOT
            driver=/workspace/publish-kagent-artifact-registry.sh
            driver_tmp="$$(mktemp /workspace/.publish-kagent-post-assemble.XXXXXX)"
            trap 'rm -f "$$driver_tmp"' EXIT
            printf '%s' "$$@" | base64 -d > "$$driver_tmp"
            printf '%s  %s\n' '${local.publication_driver_sha256}' "$$driver_tmp" \
              | sha256sum --check --status
            chmod 0555 "$$driver_tmp"
            mv -f "$$driver_tmp" "$$driver"
            trap - EXIT
            exec "$$driver" verify-platform-bindings
          EOT
          ,
          "reverify-platform-bindings-after-assembly",
        ],
        local.publication_driver_chunks,
      )
    }

    step {
      id         = "append-scan-evidence"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "append-scan-evidence"]
    }

    step {
      id         = "finalize-cloud-build-receipt"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args = concat(
        [
          "-ceu",
          <<-EOT
            driver=/workspace/publish-kagent-artifact-registry.sh
            driver_tmp="$$(mktemp /workspace/.publish-kagent-finalizer.XXXXXX)"
            trap 'rm -f "$$driver_tmp"' EXIT
            printf '%s' "$$@" | base64 -d > "$$driver_tmp"
            printf '%s  %s\n' '${local.publication_driver_sha256}' "$$driver_tmp" \
              | sha256sum --check --status
            chmod 0555 "$$driver_tmp"
            mv -f "$$driver_tmp" "$$driver"
            trap - EXIT
            exec "$$driver" finalize-receipt
          EOT
          ,
          "finalize-cloud-build-receipt",
        ],
        local.publication_driver_chunks,
      )
    }

    step {
      id         = "upload-immutable-release-receipt"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      dir        = "/workspace/release"
      env        = local.publication_environment
      args = concat(
        [
          "-ceu",
          <<-EOT
          set -o pipefail
          driver=/workspace/publish-kagent-artifact-registry.sh
          jq_path=/workspace/trusted-bin/jq
          [[ -f "$$jq_path" && ! -L "$$jq_path" && -x "$$jq_path" ]]
          printf '%s  %s\n' '${local.trusted_jq_sha256}' "$$jq_path" \
            | sha256sum --check --status
          driver_tmp="$$(mktemp /workspace/.publish-kagent-uploader.XXXXXX)"
          trap 'rm -f "$$driver_tmp"' EXIT
          printf '%s' "$$@" | base64 -d > "$$driver_tmp"
          printf '%s  %s\n' '${local.publication_driver_sha256}' "$$driver_tmp" \
            | sha256sum --check --status
          chmod 0555 "$$driver_tmp"
          mv -f "$$driver_tmp" "$$driver"
          trap - EXIT
          trusted_anchors="$$("$$driver" prepare-upload)"
          anchor_sha() {
            awk -v name="$$1" '
              $$2 == name { count += 1; sha = $$1 }
              END { if (count != 1) exit 1; print sha }
            ' <<<"$$trusted_anchors"
          }
          version="$$(printf '%s' "$$KAGENT_EXPECTED_SOURCE_TAG" | sed 's/^gcp-v//')"
          test "$$KAGENT_EXPECTED_SOURCE_TAG" = "gcp-v$$version"
          expected=(
            cloud-build-receipt.json
            "kagent-$$version.tgz"
            "kagent-crds-$$version.tgz"
            release-evidence.json
            release-lock.json
            scan-evidence.sha256
          )
          for component in controller ui golang-adk codex-harness; do
            for architecture in amd64 arm64; do
              for suffix in scan-id.txt vulnerabilities.json severities.txt scan-policy.json; do
                expected+=("$$component-linux-$$architecture-$$suffix")
              done
            done
          done

          names_file="$$(mktemp)"
          trap 'rm -f "$$names_file"' EXIT
          awk '
            NF != 2 || $$1 !~ /^[0-9a-f]{64}$$/ || $$2 !~ /^[A-Za-z0-9._-]+$$/ { exit 1 }
            { print $$2 }
          ' SHA256SUMS > "$$names_file"
          [[ "$$(wc -l < "$$names_file" | tr -d ' ')" -eq "$$${#expected[@]}" ]]
          mapfile -t actual < <(sort -u "$$names_file")
          mapfile -t wanted < <(printf '%s\n' "$$${expected[@]}" | sort -u)
          [[ "$$${#actual[@]}" -eq "$$${#expected[@]}" ]]
          [[ "$$${#wanted[@]}" -eq "$$${#expected[@]}" ]]
          [[ "$$(printf '%s\n' "$$${actual[@]}")" == "$$(printf '%s\n' "$$${wanted[@]}")" ]]
          for name in "$$${expected[@]}" SHA256SUMS release-evidence.json.sha256; do
            [[ -f "$$name" && ! -L "$$name" ]]
          done
          sha256sum --check --strict SHA256SUMS
          sha256sum --check --strict release-evidence.json.sha256

          evidence_sha="$$(anchor_sha release-evidence.json)"
          checksums_sha="$$(anchor_sha SHA256SUMS)"
          test ! -e release-receipt.json
          test ! -e release-receipt.json.sha256
          "$$jq_path" -n \
            --arg build_id "$BUILD_ID" \
            --arg source_commit '${var.source_commit}' \
            --arg version "$$version" \
            --arg evidence_sha "$$evidence_sha" \
            --arg checksums_sha "$$checksums_sha" '
              {
                schema: "yourown.chat/kagent-private-gar-receipt/v1",
                schemaVersion: 1,
                buildId: $$build_id,
                sourceCommit: $$source_commit,
                version: $$version,
                releaseEvidenceSha256: $$evidence_sha,
                checksumsSha256: $$checksums_sha
              }
            ' > release-receipt.json
          sha256sum release-receipt.json > release-receipt.json.sha256
          [[ -f release-receipt.json && ! -L release-receipt.json ]]
          [[ -f release-receipt.json.sha256 && ! -L release-receipt.json.sha256 ]]
          receipt_sha="$$(sha256sum release-receipt.json | cut -d' ' -f1)"
          receipt_sidecar_sha="$$(sha256sum release-receipt.json.sha256 | cut -d' ' -f1)"
          trusted_anchors="$$(printf '%s\n%s  release-receipt.json\n%s  release-receipt.json.sha256\n' \
            "$$trusted_anchors" "$$receipt_sha" "$$receipt_sidecar_sha")"

          upload=(
            "$$${expected[@]}"
            SHA256SUMS
            release-evidence.json.sha256
            release-receipt.json.sha256
            # The receipt is the commit marker and is uploaded only after every
            # object it roots has been generation-read back and hash-verified.
            release-receipt.json
          )
          prefix="gs://${google_storage_bucket.evidence[0].name}/kagent/$$version/$BUILD_ID"
          for name in "$$${upload[@]}"; do
            anchored_sha="$$(anchor_sha "$$name")"
            [[ "$$anchored_sha" =~ ^[0-9a-f]{64}$$ ]]
            [[ "$$(sha256sum "$$name" | cut -d' ' -f1)" == "$$anchored_sha" ]]
            destination="$$prefix/$$name"
            gcloud storage cp "$$name" "$$destination" --if-generation-match=0
            generation="$$(gcloud storage objects describe "$$destination" --format='value(generation)')"
            [[ "$$generation" =~ ^[1-9][0-9]*$$ ]]
            remote_sha="$$(gcloud storage cat "$$destination#$$generation" | sha256sum | cut -d' ' -f1)"
            [[ "$$remote_sha" == "$$anchored_sha" ]]
            printf 'immutable object: %s#%s\n' "$$destination" "$$generation"
            case "$$name" in
              release-evidence.json) evidence_generation="$$generation" ;;
              release-receipt.json) receipt_generation="$$generation" ;;
            esac
          done
          printf 'evidence_uri=%s/release-evidence.json#%s\n' "$$prefix" "$$evidence_generation"
          printf 'evidence_sha256=%s\n' "$$evidence_sha"
          printf 'receipt_uri=%s/release-receipt.json#%s\n' "$$prefix" "$$receipt_generation"
          printf 'receipt_sha256=%s\n' "$$receipt_sha"
          EOT
          ,
          "upload-immutable-release-receipt",
        ],
        local.publication_driver_chunks,
      )
    }

    options {
      disk_size_gb = 200
      logging      = "CLOUD_LOGGING_ONLY"
      # Keep the regional default-pool machine. New projects can have only five
      # E2 CPUs of default-pool quota, so either high-CPU option (8 or 32 vCPU)
      # can be rejected before the first build step runs. The two-hour timeout
      # remains the explicit capacity bound for the multi-platform build.
    }
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.release_writer,
    google_artifact_registry_repository_iam_member.staging_writer,
    google_project_iam_member.log_writer,
    google_project_iam_member.scanner,
    google_project_iam_member.build_invoker,
    google_pubsub_topic_iam_member.release_submitter,
    google_service_account_iam_member.submitter,
    google_service_account_iam_member.publisher_acts_as_self,
    google_storage_bucket_iam_member.evidence_creator,
    google_storage_bucket_iam_member.evidence_viewer,
  ]
}
