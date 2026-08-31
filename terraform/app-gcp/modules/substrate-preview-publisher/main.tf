locals {
  count                  = var.enabled ? 1 : 0
  registry_host          = "${var.artifact_registry_location}-docker.pkg.dev"
  release_prefix         = "${local.registry_host}/${var.project_id}/${var.artifact_registry_repository_id}/substrate"
  staging_prefix         = "${local.registry_host}/${var.project_id}/${var.staging_registry_repository_id}/substrate"
  publication_driver_b64 = base64encode(file("${path.module}/scripts/publish-private-gar.sh"))
  publication_driver_sha = filesha256("${path.module}/scripts/publish-private-gar.sh")
  publication_driver_chunks = [
    for index in range(ceil(length(local.publication_driver_b64) / 8000)) :
    substr(local.publication_driver_b64, index * 8000, 8000)
  ]
  publication_environment = [
    "PATH=/workspace/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HELM_BIN=/workspace/tools/helm",
    "SUBSTRATE_EVIDENCE_BUCKET=${var.evidence_bucket_name}",
    "SUBSTRATE_REGISTRY_HOST=${local.registry_host}",
    "SUBSTRATE_RELEASE_PREFIX=${local.release_prefix}",
    "SUBSTRATE_STAGING_PREFIX=${local.staging_prefix}",
  ]
  submitter_members = var.enabled ? setunion(
    toset(["serviceAccount:${var.apply_service_account_email}"]),
    var.submitter_members,
  ) : toset([])
}

resource "google_service_account" "publisher" {
  count = local.count

  project      = var.project_id
  account_id   = "substrate-publisher"
  display_name = "private Substrate publisher"
  description  = "Copies the reviewed Substrate release into private GAR, scans it and retains an immutable receipt."

  lifecycle {
    precondition {
      condition     = var.evidence_bucket_owner_enabled
      error_message = "The private Substrate publisher requires the enabled kagent publisher that owns the shared evidence bucket."
    }
  }
}

resource "google_project_iam_member" "log_writer" {
  count = local.count

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.publisher[0].email}"
}

resource "google_artifact_registry_repository_iam_member" "release_writer" {
  count = local.count

  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.publisher[0].email}"
}

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

resource "google_storage_bucket_iam_member" "evidence_creator" {
  count = local.count

  bucket = var.evidence_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.publisher[0].email}"

  condition {
    title       = "substrate-${var.release_version}-create"
    description = "Create objects only under the exact reviewed Substrate release prefix."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.evidence_bucket_name}/objects/substrate/${var.release_version}/\")"
  }
}

# The build reads back exact uploaded objects to record their immutable GCS
# generations. Keep this grant bucket-scoped and separate from objectCreator;
# objectAdmin is neither required nor allowed.
resource "google_storage_bucket_iam_member" "evidence_viewer" {
  count = local.count

  bucket = var.evidence_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.publisher[0].email}"

  condition {
    title       = "substrate-${var.release_version}-read"
    description = "Read objects only under the exact reviewed Substrate release prefix."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.evidence_bucket_name}/objects/substrate/${var.release_version}/\")"
  }
}

resource "google_project_iam_custom_role" "build_invoker" {
  count = local.count

  project     = var.project_id
  role_id     = "substratePrivateBuildInvoker"
  title       = "private Substrate build invoker"
  description = "Allows only creation of the Pub/Sub-triggered private Substrate build."
  permissions = ["cloudbuild.builds.create"]
  stage       = "GA"
}

resource "google_project_iam_member" "build_invoker" {
  count = local.count

  project = var.project_id
  role    = google_project_iam_custom_role.build_invoker[0].id
  member  = "serviceAccount:${google_service_account.publisher[0].email}"
}

resource "google_service_account_iam_member" "apply_acts_as_publisher" {
  count = local.count

  service_account_id = google_service_account.publisher[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.apply_service_account_email}"
}

resource "google_service_account_iam_member" "publisher_acts_as_self" {
  count = local.count

  service_account_id = google_service_account.publisher[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.publisher[0].email}"
}

resource "google_project_iam_custom_role" "apply_pubsub_manager" {
  count = local.count

  project     = var.project_id
  role_id     = "substratePrivatePubsubManager"
  title       = "private Substrate Pub/Sub manager"
  description = "Allows Terraform to manage only the private Substrate release topic and its policy."
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

resource "google_pubsub_topic" "release_request" {
  count = local.count

  project = var.project_id
  name    = "substrate-private-release"

  depends_on = [google_project_iam_member.apply_pubsub_manager]
}

resource "google_pubsub_topic_iam_member" "release_submitter" {
  for_each = local.submitter_members

  project = var.project_id
  topic   = google_pubsub_topic.release_request[0].name
  role    = "roles/pubsub.publisher"
  member  = each.value
}

resource "google_cloudbuild_trigger" "release" {
  count = local.count

  project         = var.project_id
  location        = var.region
  name            = "substrate-private-release"
  description     = "Copies the reviewed Substrate v0.0.22 external-control-plane-only image set into private GAR, scans it and writes retained evidence."
  service_account = google_service_account.publisher[0].id

  pubsub_config {
    topic = google_pubsub_topic.release_request[0].id
  }

  substitutions = {
    _RELEASE_VERSION = "$(body.message.attributes.releaseVersion)"
  }

  filter = "_RELEASE_VERSION == \"${var.release_version}\""

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
          release_version="$_RELEASE_VERSION"
          test "$$release_version" = '${var.release_version}'

          git clone --filter=blob:none --no-tags \
            "${var.github_remote_uri}" /workspace/source
          cd /workspace/source
          git fetch --force origin \
            "refs/tags/${var.source_tag}:refs/tags/${var.source_tag}"
          test "$$(git cat-file -t "refs/tags/${var.source_tag}")" = tag
          tag_object="$$(git rev-parse "refs/tags/${var.source_tag}")"
          tag_commit="$$(git rev-parse "refs/tags/${var.source_tag}^{}")"
          test "$$tag_object" = "${var.source_tag_object}"
          test "$$tag_commit" = "${var.source_commit}"
          git checkout --detach "${var.source_commit}"
          test -z "$$(git status --porcelain)"
          source_tree="$$(git rev-parse "${var.source_commit}^{tree}")"
          chart_tree="$$(git rev-parse "${var.source_commit}:charts")"

          printf '%s' "$$release_version" > /workspace/substrate-release-version
          printf '%s' '${var.source_tag}' > /workspace/substrate-source-tag
          printf '%s' '${var.source_commit}' > /workspace/substrate-source-commit
          printf '%s' "$$tag_object" > /workspace/substrate-source-tag-object
          printf '%s' "$$source_tree" > /workspace/substrate-source-tree
          printf '%s' "$$chart_tree" > /workspace/substrate-chart-tree
          printf '%s' "$BUILD_ID" > /workspace/substrate-build-id
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
            output=/workspace/publish-substrate-private-gar.sh
            printf '%s' "$$@" | base64 -d > "$$output"
            printf '%s  %s\n' '${local.publication_driver_sha}' "$$output" \
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
      id         = "install-pinned-release-tools"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      args = [
        "-ceu",
        <<-EOT
          mkdir -p /workspace/tools /workspace/tool-downloads/helm
          curl --fail --location --silent --show-error \
            https://get.helm.sh/helm-v3.21.4-linux-amd64.tar.gz \
            --output /workspace/tool-downloads/helm.tgz
          printf '%s  %s\n' \
            '61f88ab166748cb19604d7884cb100ae9ccb13804ddeb98e08af167eacbb6a14' \
            /workspace/tool-downloads/helm.tgz | sha256sum --check --status
          tar -xzf /workspace/tool-downloads/helm.tgz \
            -C /workspace/tool-downloads/helm --strip-components=1 linux-amd64/helm
          install -m 0555 /workspace/tool-downloads/helm/helm /workspace/tools/helm

          curl --fail --location --silent --show-error \
            https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-amd64 \
            --output /workspace/tools/jq
          printf '%s  %s\n' \
            '020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d' \
            /workspace/tools/jq | sha256sum --check --status
          chmod 0555 /workspace/tools/jq
          /workspace/tools/helm version --short
          /workspace/tools/jq --version
        EOT
      ]
    }

    step {
      id         = "reject-existing-final-refs"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "reject-existing"]
    }

    step {
      id         = "stage-exact-source-image-indexes"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "stage-source-images"]
    }

    step {
      id         = "verify-staged-image-indexes"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "verify-candidates"]
    }

    step {
      id         = "record-staged-platform-digests"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "record-platforms"]
    }

    step {
      id         = "package-and-reproduce-private-charts"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "package-charts"]
    }

    step {
      id         = "scan-staged-images"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "scan-images"]
    }

    step {
      id         = "acquire-immutable-release-lock"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "acquire-lock"]
    }

    step {
      id         = "recheck-final-refs"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "reject-existing"]
    }

    step {
      id         = "promote-private-image-indexes"
      name       = "gcr.io/cloud-builders/docker@sha256:d1797996867921778f1adbb7e493baaaf2f6b21e107599c0aab48c2ec06ff311"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "promote-images"]
    }

    step {
      id         = "publish-private-charts"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "publish-charts"]
    }

    step {
      id         = "verify-private-final-digests"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "verify-finals"]
    }

    step {
      id         = "assemble-private-release-evidence"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "assemble-evidence"]
    }

    step {
      id         = "upload-retained-private-receipt"
      name       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"
      entrypoint = "bash"
      env        = local.publication_environment
      args       = ["/workspace/publish-substrate-private-gar.sh", "upload-evidence"]
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.release_writer,
    google_artifact_registry_repository_iam_member.staging_writer,
    google_project_iam_member.build_invoker,
    google_project_iam_member.log_writer,
    google_project_iam_member.scanner,
    google_service_account_iam_member.apply_acts_as_publisher,
    google_service_account_iam_member.publisher_acts_as_self,
    google_storage_bucket_iam_member.evidence_creator,
    google_storage_bucket_iam_member.evidence_viewer,
  ]
}
