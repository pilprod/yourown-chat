data "google_project" "this" {
  project_id = var.project_id
}

locals {
  exec_sa_id         = "${var.name_prefix}-clouddeploy"
  pipeline_name      = "${var.name_prefix}-pipeline"
  deploy_agent_email = "service-${data.google_project.this.number}@gcp-sa-clouddeploy.iam.gserviceaccount.com"

  # Targets keyed by stage name (order-independent); the pipeline below drives
  # the promotion order from the ordered var.stages list.
  targets = { for s in var.stages : s.name => s }
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

# One target per stage. Every target points at the SAME cluster; the deploy
# namespace and per-env config diverge via the Skaffold profile bound to the
# stage in the pipeline below. `require_approval` and the post-deploy VERIFY
# execution usage are per stage.
resource "google_clouddeploy_target" "stage" {
  for_each = local.targets

  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-${each.value.name}"

  require_approval = each.value.require_approval

  gke {
    cluster = var.gke_cluster_id
  }

  execution_configs {
    usages          = each.value.verify ? ["RENDER", "DEPLOY", "VERIFY"] : ["RENDER", "DEPLOY"]
    service_account = google_service_account.exec.email
  }

  labels = var.labels

  depends_on = [google_project_iam_member.exec]
}

# Serial promotion pipeline. var.stages is ORDER-SENSITIVE -- the first stage is
# the release entrypoint and each subsequent stage is a promotion target; the
# dynamic block iterates the list in order to preserve the dev -> prod flow.
resource "google_clouddeploy_delivery_pipeline" "this" {
  project  = var.project_id
  location = var.region
  name     = local.pipeline_name

  labels = var.labels

  serial_pipeline {
    dynamic "stages" {
      for_each = var.stages
      iterator = stage

      content {
        target_id = google_clouddeploy_target.stage[stage.value.name].name
        profiles  = stage.value.profiles

        strategy {
          standard {
            # Run the Skaffold `verify` tests after deploy on stages that opt in
            # (the target also carries the VERIFY execution usage).
            verify = stage.value.verify
          }
        }
      }
    }
  }
}
