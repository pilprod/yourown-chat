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

  docker_config {
    immutable_tags = var.immutable_tags
  }

  # Automatic vulnerability scanning (Artifact Analysis) for images pushed to
  # THIS repository. Scanning is a two-part switch in GCP: the project-level
  # containerscanning API (enabled by project_services when the stack input is
  # on) plus this per-repository gate -- INHERITED follows the project setting,
  # DISABLED opts the repo out. Cost: ~$0.26 per scanned image digest, so it is
  # a paid opt-in (default off).
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
}
