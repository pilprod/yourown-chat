locals {
  # Secrets whose value Terraform generates.
  generated = { for k, v in var.secrets : k => v if v.generate }

  # Secret IDs that receive an initial version (generated OR explicitly provided).
  # Iterate the ID set — not the secret objects — so for_each stays non-sensitive
  # even when a provided value is (e.g. the Cloudflare Origin CA private key): the
  # secret *names* are not secret. The predicate touches v.value, so the raw set
  # inherits its sensitivity; nonsensitive() unwraps it (only names leak), and
  # try() falls back when no provided value happens to be sensitive.
  with_version_raw = toset([
    for k, v in var.secrets : k
    if v.generate || v.value != null
  ])
  with_version = try(nonsensitive(local.with_version_raw), local.with_version_raw)

  # Flatten (secret, accessor) pairs for per-secret least-privilege IAM.
  accessor_bindings = merge([
    for k, v in var.secrets : {
      for m in v.accessors : "${k}::${m}" => { secret = k, member = m }
    }
  ]...)
}

resource "random_password" "this" {
  for_each = local.generated

  length  = each.value.length
  special = true
}

resource "google_secret_manager_secret" "this" {
  for_each = var.secrets

  project   = var.project_id
  secret_id = each.key
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
  for_each = local.with_version

  secret = google_secret_manager_secret.this[each.value].id
  secret_data = sensitive(
    var.secrets[each.value].generate ? random_password.this[each.value].result : var.secrets[each.value].value
  )
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = local.accessor_bindings

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}
