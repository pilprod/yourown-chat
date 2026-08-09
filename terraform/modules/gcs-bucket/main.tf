resource "google_storage_bucket" "this" {
  project                     = var.project_id
  name                        = var.name
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy
  labels                      = var.labels

  dynamic "encryption" {
    for_each = var.kms_key_name == null ? [] : [var.kms_key_name]
    content { default_kms_key_name = encryption.value }
  }

  lifecycle_rule {
    condition { age = var.retention_days }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket_iam_member" "this" {
  for_each = var.members
  bucket   = google_storage_bucket.this.name
  role     = var.member_role
  member   = each.value
}
