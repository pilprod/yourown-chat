locals {
  wi_member = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.ksa_name}]"
}

resource "google_service_account" "this" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = var.display_name != "" ? var.display_name : "WI SA for ${var.namespace}/${var.ksa_name}"
}

# Let the specific KSA impersonate this GSA (Workload Identity).
resource "google_service_account_iam_member" "wi_user" {
  count = var.primary_ksa_binding_enabled ? 1 : 0

  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wi_member
}

resource "google_service_account_iam_member" "wi_user_additional" {
  for_each = {
    for binding in var.additional_ksa_bindings :
    "${binding.namespace}/${binding.ksa_name}" => binding
  }

  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.namespace}/${each.value.ksa_name}]"
}

# Optional least-privilege project roles.
resource "google_project_iam_member" "roles" {
  for_each = toset(var.project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.this.email}"
}
