locals {
  registry_host   = "${var.location}-docker.pkg.dev"
  repository_path = "${local.registry_host}/${var.project_id}/${var.repository_id}"
}

resource "google_artifact_registry_repository" "this" {
  project       = var.project_id
  location      = var.location
  repository_id = var.repository_id
  description   = var.description
  format        = "DOCKER"
  kms_key_name  = var.kms_key_name
  labels        = var.labels

  lifecycle {
    precondition {
      condition     = !var.immutable_tags || var.delete_tagged_days == 0
      error_message = "delete_tagged_days cannot be enabled for an immutable release repository."
    }
  }

  docker_config {
    immutable_tags = var.immutable_tags
  }

  # Automatic vulnerability scanning (Artifact Analysis) for images pushed to
  # THIS repository. Scanning is a two-part switch in GCP: the project-level
  # containerscanning API (kept ready by project_services) plus this
  # per-repository gate. INHERITED activates scans immediately; DISABLED opts
  # the repository out and is the cost-safe baseline.
  vulnerability_scanning_config {
    enablement_config = var.vulnerability_scanning ? "INHERITED" : "DISABLED"
  }

  # Reclaim storage from throwaway/untagged image layers.
  dynamic "cleanup_policies" {
    for_each = var.keep_untagged_days > 0 ? [1] : []
    content {
      id     = "delete-untagged"
      action = "DELETE"
      condition {
        tag_state  = "UNTAGGED"
        older_than = "${var.keep_untagged_days * 24}h"
      }
    }
  }

  dynamic "cleanup_policies" {
    for_each = var.keep_recent_versions > 0 ? [1] : []
    content {
      id     = "keep-recent"
      action = "KEEP"
      most_recent_versions {
        keep_count = var.keep_recent_versions
      }
    }
  }

  dynamic "cleanup_policies" {
    for_each = var.delete_tagged_days > 0 ? [1] : []
    content {
      id     = "delete-old-tagged"
      action = "DELETE"
      condition {
        tag_state  = "TAGGED"
        older_than = "${var.delete_tagged_days * 24}h"
      }
    }
  }
}

# Artifact Registry Admin can delete images and repositories, so the MCP gets
# a narrow custom role containing only repository read/update permissions.
resource "google_project_iam_custom_role" "scanning_controller" {
  count = var.scanning_controller_member == null ? 0 : 1

  project     = var.project_id
  role_id     = "artifactScanningController"
  title       = "Artifact scanning controller"
  description = "Toggle vulnerability scanning for an allowlisted Artifact Registry repository."
  permissions = [
    "artifactregistry.repositories.get",
    "artifactregistry.repositories.update",
  ]
  stage = "GA"
}

resource "google_project_iam_member" "scanning_controller" {
  count = var.scanning_controller_member == null ? 0 : 1

  project = var.project_id
  role    = google_project_iam_custom_role.scanning_controller[0].name
  member  = var.scanning_controller_member
}
