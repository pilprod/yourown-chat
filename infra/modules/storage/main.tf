locals {
  bucket_name       = "${var.name_prefix}-${random_id.suffix.hex}"
  filestore_enabled = var.create_filestore_hmac
  access_secret_id  = "${var.name_prefix}-filestore-access-key"
  secret_secret_id  = "${var.name_prefix}-filestore-secret-key"
}

# Buckets share a global namespace; a short suffix avoids collisions.
resource "random_id" "suffix" {
  byte_length = 3
}

resource "google_storage_bucket" "this" {
  project  = var.project_id
  name     = local.bucket_name
  location = var.location

  storage_class               = var.storage_class
  uniform_bucket_level_access = true
  public_access_prevention    = var.public_access_prevention
  force_destroy               = var.force_destroy

  labels = var.labels

  versioning {
    enabled = var.versioning_enabled
  }

  dynamic "encryption" {
    for_each = var.kms_key_name == null ? [] : [var.kms_key_name]
    content {
      default_kms_key_name = encryption.value
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.lifecycle_rules
    content {
      action {
        type          = lifecycle_rule.value.action_type
        storage_class = lifecycle_rule.value.action_storage_class
      }
      condition {
        age                        = lifecycle_rule.value.age
        num_newer_versions         = lifecycle_rule.value.num_newer_versions
        days_since_noncurrent_time = lifecycle_rule.value.days_since_noncurrent
        with_state                 = lifecycle_rule.value.with_state
      }
    }
  }
}

# --- Optional Mattermost S3-compatible filestore credentials ----------------
# Dedicated identity, scoped to this bucket only (least privilege).
resource "google_service_account" "filestore" {
  count = local.filestore_enabled ? 1 : 0

  project      = var.project_id
  account_id   = substr("${var.name_prefix}-fs", 0, 30)
  display_name = "Filestore HMAC SA for ${local.bucket_name}"
}

resource "google_storage_bucket_iam_member" "filestore" {
  count = local.filestore_enabled ? 1 : 0

  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.filestore[0].email}"
}

# S3-interoperability HMAC key for the dedicated SA.
resource "google_storage_hmac_key" "filestore" {
  count = local.filestore_enabled ? 1 : 0

  project               = var.project_id
  service_account_email = google_service_account.filestore[0].email
}

resource "google_secret_manager_secret" "filestore_access_key" {
  count = local.filestore_enabled ? 1 : 0

  project   = var.project_id
  secret_id = local.access_secret_id
  labels    = var.labels

  replication {
    user_managed {
      dynamic "replicas" {
        for_each = var.secret_replica_locations
        content {
          location = replicas.value
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "filestore_access_key" {
  count = local.filestore_enabled ? 1 : 0

  secret      = google_secret_manager_secret.filestore_access_key[0].id
  secret_data = google_storage_hmac_key.filestore[0].access_id
}

resource "google_secret_manager_secret" "filestore_secret_key" {
  count = local.filestore_enabled ? 1 : 0

  project   = var.project_id
  secret_id = local.secret_secret_id
  labels    = var.labels

  replication {
    user_managed {
      dynamic "replicas" {
        for_each = var.secret_replica_locations
        content {
          location = replicas.value
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "filestore_secret_key" {
  count = local.filestore_enabled ? 1 : 0

  secret      = google_secret_manager_secret.filestore_secret_key[0].id
  secret_data = sensitive(google_storage_hmac_key.filestore[0].secret)
}

resource "google_secret_manager_secret_iam_member" "filestore_access_accessor" {
  for_each = local.filestore_enabled ? toset(var.filestore_secret_accessors) : toset([])

  project   = var.project_id
  secret_id = google_secret_manager_secret.filestore_access_key[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

resource "google_secret_manager_secret_iam_member" "filestore_secret_accessor" {
  for_each = local.filestore_enabled ? toset(var.filestore_secret_accessors) : toset([])

  project   = var.project_id
  secret_id = google_secret_manager_secret.filestore_secret_key[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
