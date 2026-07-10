locals {
  instance_name  = "${var.name_prefix}-pg-${random_id.suffix.hex}"
  secret_id      = "${var.name_prefix}-cloudsql-${var.db_user_name}-password"
  conn_secret_id = "${var.name_prefix}-cloudsql-${var.database_name}-connection"

  connection_uri = "postgres://${var.db_user_name}:${random_password.user.result}@${google_sql_database_instance.this.private_ip_address}:5432/${var.database_name}?sslmode=require&connect_timeout=10"
}

# Instance names are blocked from reuse for ~1 week after deletion; a suffix
# keeps re-creates frictionless.
resource "random_id" "suffix" {
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
