# The plaintext exists only during apply. Neither the generated value nor the
# Secret Manager write-only argument is persisted in Terraform state.
ephemeral "random_password" "initial" {
  length           = 32
  special          = true
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "!#$%&*+-=?@^_"
}

resource "google_secret_manager_secret" "this" {
  project   = var.project_id
  secret_id = var.secret_id
  labels    = var.labels

  replication {
    user_managed {
      replicas {
        location = var.location

        customer_managed_encryption {
          kms_key_name = var.kms_key_name
        }
      }
    }
  }

}

resource "google_secret_manager_secret_version" "initial" {
  secret                 = google_secret_manager_secret.this.id
  secret_data_wo         = ephemeral.random_password.initial.result
  secret_data_wo_version = var.password_version
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = var.accessor_members

  project   = var.project_id
  secret_id = google_secret_manager_secret.this.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
