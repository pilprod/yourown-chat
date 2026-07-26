locals {
  accessor_bindings = toset(var.accessors)
}

resource "google_secret_manager_secret" "this" {
  project   = var.project_id
  secret_id = var.secret_id
  labels    = var.labels

  replication {
    user_managed {
      dynamic "replicas" {
        for_each = var.replica_locations
        content {
          location = replicas.value

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
}

resource "google_secret_manager_secret_version" "this" {
  secret                 = google_secret_manager_secret.this.id
  secret_data_wo         = var.secret_data
  secret_data_wo_version = var.secret_data_version

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = local.accessor_bindings

  project   = var.project_id
  secret_id = google_secret_manager_secret.this.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
