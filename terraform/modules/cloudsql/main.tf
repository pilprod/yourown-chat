locals {
  instance_name  = var.instance_name_random_suffix ? "${var.region}-${random_id.suffix[0].hex}" : var.region
  secret_id      = "cloudsql-${var.db_user_name}-password"
  conn_secret_id = "cloudsql-${var.database_name}-connection"

  connection_uri = "postgres://${var.db_user_name}:${random_password.user.result}@${google_sql_database_instance.this.private_ip_address}:5432/${var.database_name}?sslmode=require&connect_timeout=10"
}

# Name after the region alone (no "-pg" type suffix): it is THE Postgres
# instance, mirroring the GKE cluster which drops "-gke". europe-west3.
#
# Deterministic instance name by default. Cloud SQL blocks reuse of an instance
# name for ~1 week after deletion, so if you destroy and immediately re-create,
# set instance_name_random_suffix = true to get a fresh, non-colliding name.
# (Terraform can't "try the plain name, then fall back on conflict" -- the name
# is fixed at plan time -- so this is an explicit opt-in rather than automatic.)
resource "random_id" "suffix" {
  count       = var.instance_name_random_suffix ? 1 : 0
  byte_length = 2
}

resource "random_password" "user" {
  length           = 32
  special          = true
  override_special = "!#%*_-+="
}

resource "google_sql_database_instance" "this" {
  project          = var.project_id
  name             = local.instance_name
  region           = var.region
  database_version = var.database_version

  deletion_protection = var.deletion_protection

  # CMEK: null keeps Google-managed encryption. When set, the Cloud SQL service
  # agent must already hold encrypterDecrypter on the key (wired via the kms
  # component's dependency edge). ForceNew -- the key cannot be changed in place.
  encryption_key_name = var.encryption_key_name

  settings {
    tier              = var.tier
    edition           = var.edition
    availability_type = var.availability_type
    disk_size         = var.disk_size_gb
    disk_type         = var.disk_type
    disk_autoresize   = var.disk_autoresize
    user_labels       = var.user_labels

    ip_configuration {
      # Private IP only: no public IPv4 endpoint.
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = var.backup_enabled
      start_time                     = var.backup_start_time
      point_in_time_recovery_enabled = var.point_in_time_recovery_enabled
      transaction_log_retention_days = var.transaction_log_retention_days

      backup_retention_settings {
        retained_backups = var.backup_retained_count
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }

    dynamic "database_flags" {
      for_each = var.database_flags
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }
  }
}

resource "google_sql_database" "app" {
  project  = var.project_id
  name     = var.database_name
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "app" {
  project  = var.project_id
  name     = var.db_user_name
  instance = google_sql_database_instance.this.name
  password = random_password.user.result
}

# Store the generated credential in Secret Manager (never in state consumers).
resource "google_secret_manager_secret" "db_password" {
  project   = var.project_id
  secret_id = local.secret_id

  labels = var.user_labels

  replication {
    user_managed {
      replicas {
        location = var.region

        dynamic "customer_managed_encryption" {
          for_each = var.encryption_key_name == null ? [] : [var.encryption_key_name]
          content {
            kms_key_name = customer_managed_encryption.value
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.user.result
}

resource "google_secret_manager_secret_iam_member" "db_password_accessor" {
  for_each = toset(var.password_secret_accessors)

  project   = var.project_id
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

# Optional ready-to-use connection URI secret (e.g. for Mattermost external DB).
resource "google_secret_manager_secret" "connection" {
  count = var.create_connection_secret ? 1 : 0

  project   = var.project_id
  secret_id = local.conn_secret_id
  labels    = var.user_labels

  replication {
    user_managed {
      replicas {
        location = var.region

        dynamic "customer_managed_encryption" {
          for_each = var.encryption_key_name == null ? [] : [var.encryption_key_name]
          content {
            kms_key_name = customer_managed_encryption.value
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "connection" {
  count = var.create_connection_secret ? 1 : 0

  secret      = google_secret_manager_secret.connection[0].id
  secret_data = sensitive(local.connection_uri)
}

resource "google_secret_manager_secret_iam_member" "connection_accessor" {
  for_each = var.create_connection_secret ? toset(var.connection_secret_accessors) : toset([])

  project   = var.project_id
  secret_id = google_secret_manager_secret.connection[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
