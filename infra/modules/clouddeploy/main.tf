data "google_project" "this" {
  project_id = var.project_id
}

locals {
  exec_sa_id         = "${var.name_prefix}-clouddeploy"
  pipeline_name      = "${var.name_prefix}-pipeline"
  deploy_agent_email = "service-${data.google_project.this.number}@gcp-sa-clouddeploy.iam.gserviceaccount.com"
}

# Execution identity Cloud Deploy uses to render and deploy.
resource "google_service_account" "exec" {
  project      = var.project_id
  account_id   = local.exec_sa_id
  display_name = "Cloud Deploy execution SA (${var.name_prefix})"
}

resource "google_project_iam_member" "exec" {
  for_each = toset(var.execution_sa_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.exec.email}"
}

# The Cloud Deploy service agent must be able to impersonate the execution SA.
resource "google_service_account_iam_member" "agent_act_as_exec" {
  service_account_id = google_service_account.exec.id
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.deploy_agent_email}"
}

resource "google_clouddeploy_target" "gke" {
  project  = var.project_id
  location = var.region
  name     = var.target_name

  require_approval = var.require_approval

  gke {
    cluster = var.gke_cluster_id
  }

  execution_configs {
    usages          = ["RENDER", "DEPLOY"]
    service_account = google_service_account.exec.email
  }

  labels = var.labels

  depends_on = [google_project_iam_member.exec]
}

resource "google_clouddeploy_delivery_pipeline" "this" {
  project  = var.project_id
  location = var.region
  name     = local.pipeline_name

  labels = var.labels

  serial_pipeline {
    stages {
      target_id = google_clouddeploy_target.gke.name
    }
  }
}
