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
  publication_environment = [
    "KAGENT_ARTIFACT_PREFIX=${local.artifact_repository_prefix}",
    "KAGENT_EVIDENCE_BUCKET=${var.evidence_bucket_name}",
    "KAGENT_REGISTRY_HOST=${local.registry_host}",
    "KAGENT_STAGING_PREFIX=${local.staging_repository_prefix}",
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
# from this same bucket. It cannot list, mutate or delete objects beyond the
# read semantics of the bucket-scoped viewer role.
resource "google_storage_bucket_iam_member" "evidence_viewer" {
  count = local.count

  bucket = google_storage_bucket.evidence[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.publisher[0].email}"

  condition {
    title       = "substrate-0.0.22-private.1-read"
    description = "Read only the exact private Substrate evidence handoff consumed by this kagent rail."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.evidence[0].name}/objects/substrate/0.0.22-private.1/\")"
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
            'gs://${var.evidence_bucket_name}/substrate/0.0.22-private.1/release-evidence.json#'[1-9][0-9]*) ;;
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
            --workdir /workspace/source \
            --env SUBSTRATE_RELEASE_RECEIPT=/workspace/private-substrate/release-evidence.json \
            --env HELM_REGISTRY_CONFIG=/workspace/private-substrate/registry-config.json \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/source/scripts/verify-cloud-build-fork-preview-source.sh \
            "$$(< /workspace/kagent-release-version)" \
            "${var.source_commit}"
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
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_STAGING_PREFIX \
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
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_STAGING_PREFIX \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/publish-kagent-artifact-registry.sh record-platforms
        EOT
      ]
    }

    step {
      id         = "package-and-reproduce-charts"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          docker run --rm \
            --volume /workspace:/workspace \
            --workdir /workspace/source \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/source/scripts/cloud-build-fork-preview-charts.sh \
            package "$$(< /workspace/kagent-release-version)"
        EOT
      ]
    }

    step {
      id         = "scan-candidate-images"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-kagent-artifact-registry.sh", "scan-images"]
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
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_STAGING_PREFIX \
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
            --volume /workspace:/workspace \
            --env KAGENT_ARTIFACT_PREFIX \
            --env KAGENT_REGISTRY_HOST \
            --env KAGENT_STAGING_PREFIX \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/publish-kagent-artifact-registry.sh assemble-evidence
        EOT
      ]
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
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          docker run --rm \
            --volume /workspace:/workspace \
            --entrypoint python3 \
            "gcr.io/$PROJECT_ID/kagent-fork-preview-tools:$BUILD_ID" \
            /workspace/source/scripts/finalize-cloud-build-fork-preview-receipt.py \
            "$BUILD_ID" "$PROJECT_ID" "${var.source_commit}" \
            "$$(< /workspace/kagent-release-version)" \
            "$$(< /workspace/kagent-source-tag)" /workspace/release
        EOT
      ]
    }

    step {
      id         = "upload-immutable-release-receipt"
      name       = "gcr.io/cloud-builders/gcloud@sha256:3bcfea90f299ae18ced1c0bce4ec035bc4d19049f16c22690ba7c4e730478fbc"
      entrypoint = "bash"
      dir        = "/workspace/release"
      args = [
        "-ceu",
        <<-EOT
          version="$$(< /workspace/kagent-release-version)"
          cat release-evidence.json
          cat release-evidence.json.sha256
          gcloud storage cp ./* \
            "gs://${google_storage_bucket.evidence[0].name}/kagent/$$version/$BUILD_ID/"
          printf 'release receipt: gs://%s/kagent/%s/%s/\n' \
            "${google_storage_bucket.evidence[0].name}" "$$version" "$BUILD_ID"
        EOT
      ]
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
