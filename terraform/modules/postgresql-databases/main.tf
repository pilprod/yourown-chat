resource "random_password" "this" {
  length           = 32
  special          = true
  override_special = "-_.~"
  keepers          = { rotation = var.password_rotation }
}

resource "google_sql_database" "this" {
  for_each = var.database_names
  project  = var.project_id
  instance = var.instance_name
  name     = each.value
}

resource "google_sql_user" "this" {
  project  = var.project_id
  instance = var.instance_name
  name     = var.user_name
  password = random_password.this.result
}

resource "google_secret_manager_secret" "password" {
  project   = var.project_id
  secret_id = var.password_secret_id
  labels    = var.labels

  replication {
    user_managed {
      replicas {
        location = var.secret_location
        dynamic "customer_managed_encryption" {
          for_each = var.kms_key_name == null ? [] : [var.kms_key_name]
          content { kms_key_name = customer_managed_encryption.value }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "password" {
  secret      = google_secret_manager_secret.password.id
  secret_data = random_password.this.result
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each  = var.password_secret_accessors
  project   = var.project_id
  secret_id = google_secret_manager_secret.password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
