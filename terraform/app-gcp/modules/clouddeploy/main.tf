locals {
  exec_sa_id    = "deploy-${var.pipeline_name}"
  pipeline_name = var.pipeline_name

  # Targets keyed by stage name (order-independent); the pipeline below drives
  # the promotion order from the ordered var.stages list.
  targets = { for s in var.stages : s.name => s }
}

# The Cloud Deploy service agent is created lazily on first API use.
resource "google_project_service_identity" "clouddeploy" {
  provider = google-beta
  project  = var.project_id
  service  = "clouddeploy.googleapis.com"
}

# Execution identity Cloud Deploy uses to render and deploy.
resource "google_service_account" "exec" {
  project      = var.project_id
  account_id   = local.exec_sa_id
  display_name = "Cloud Deploy execution SA"
}

resource "google_project_iam_member" "exec" {
  for_each = toset(var.execution_sa_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.exec.email}"
}

# The Cloud Deploy service agent must be able to impersonate the execution SA.
resource "google_service_account_iam_member" "agent_act_as_exec" {
  service_account_id = google_service_account.exec.id
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_project_service_identity.clouddeploy.email}"
}

# One target per stage. Every target points at the same cluster; Skaffold
# profiles select the workload set for each stage.
resource "google_clouddeploy_target" "stage" {
  for_each = local.targets

  project          = var.project_id
  location         = var.region
  name             = "${var.pipeline_name}-${each.value.name}"
  require_approval = each.value.require_approval

  gke {
    cluster = var.gke_cluster_id
  }

  execution_configs {
    usages = concat(
      ["RENDER", "DEPLOY"],
      each.value.verify ? ["VERIFY"] : [],
      length(each.value.predeploy_actions) > 0 ? ["PREDEPLOY"] : [],
      length(each.value.postdeploy_actions) > 0 ? ["POSTDEPLOY"] : [],
    )
    service_account = google_service_account.exec.email
  }

  labels     = var.labels
  depends_on = [google_project_iam_member.exec]
}

# Serial promotion pipeline. Each module instance owns one workload family;
# profiles change environment values without pulling unrelated components into
# the same rollout.
resource "google_clouddeploy_delivery_pipeline" "this" {
  project  = var.project_id
  location = var.region
  name     = local.pipeline_name
  labels   = var.labels

  serial_pipeline {
    dynamic "stages" {
      for_each = var.stages
      iterator = stage

      content {
        target_id = google_clouddeploy_target.stage[stage.value.name].name
        profiles  = stage.value.profiles

        dynamic "deploy_parameters" {
          for_each = length(var.deploy_parameters) > 0 ? [1] : []
          content {
            values = var.deploy_parameters
          }
        }

        dynamic "strategy" {
          for_each = stage.value.verify || length(stage.value.predeploy_actions) > 0 || length(stage.value.postdeploy_actions) > 0 ? [1] : []
          content {
            standard {
              verify = stage.value.verify

              dynamic "predeploy" {
                for_each = length(stage.value.predeploy_actions) > 0 ? [1] : []
                content {
                  actions = stage.value.predeploy_actions
                }
              }

              dynamic "postdeploy" {
                for_each = length(stage.value.postdeploy_actions) > 0 ? [1] : []
                content {
                  actions = stage.value.postdeploy_actions
                }
              }
            }
          }
        }
      }
    }
  }
}
