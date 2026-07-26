locals {
  accessor_bindings = toset(var.accessors)
}

import {
  for_each = var.adopt_existing ? toset(["this"]) : toset([])

  to = google_secret_manager_secret.this
  id = "projects/${var.project_id}/secrets/${var.secret_id}"
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

# Preserve the bootstrap version already tracked at this address. The actual
# payload was written through secret_data_wo and is intentionally unavailable
# to Terraform now; later rotations are added out-of-band and consumed through
# Secret Manager's `latest` alias.
resource "google_secret_manager_secret_version" "this" {
  secret                 = google_secret_manager_secret.this.id
  secret_data_wo         = "managed-out-of-band"
  secret_data_wo_version = 1

  lifecycle {
    ignore_changes = [
      secret_data_wo,
      secret_data_wo_version,
    ]
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = local.accessor_bindings

  project   = var.project_id
  secret_id = google_secret_manager_secret.this.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
