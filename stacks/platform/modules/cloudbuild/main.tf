locals {
  sa_id = "${var.name_prefix}-cloudbuild"

  # Baseline project roles the build needs to run and emit logs.
  base_project_roles = ["roles/logging.logWriter"]

  release_roles = var.grant_clouddeploy_releaser ? ["roles/clouddeploy.releaser"] : []

  project_roles = toset(concat(
    local.base_project_roles,
    local.release_roles,
    var.additional_project_roles,
  ))
}

# Dedicated build identity (never rely on the legacy default Cloud Build SA).
resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = local.sa_id
  display_name = "Cloud Build SA (${var.name_prefix})"
}

resource "google_project_iam_member" "build" {
  for_each = local.project_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Repo-scoped push permission (least privilege vs project-wide writer).
resource "google_artifact_registry_repository_iam_member" "writer" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

# Allow the build to actAs the Cloud Deploy execution SA when creating a release.
resource "google_service_account_iam_member" "act_as_deploy" {
  count = var.clouddeploy_execution_sa_email == null ? 0 : 1

  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.clouddeploy_execution_sa_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.build.email}"
}
