locals {
  count = var.enabled ? 1 : 0
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

# Deliberately creates only the container. A dedicated classic GitHub PAT with
# the minimal write:packages scope is added as one exact Secret Manager version
# outside Terraform so no credential byte can enter configuration or state.
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

resource "google_secret_manager_secret_iam_member" "publisher_accessor" {
  count = local.count

  project   = var.project_id
  secret_id = google_secret_manager_secret.ghcr_write[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.publisher[0].email}"
}

# The apply identity always needs actAs to materialize a Cloud Build submission
# that names this SA. Additional human or MCP submitters must be named
# explicitly; no project-wide serviceAccountUser grant is used.
resource "google_service_account_iam_member" "submitter" {
  for_each = local.submitter_members

  service_account_id = google_service_account.publisher[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}
