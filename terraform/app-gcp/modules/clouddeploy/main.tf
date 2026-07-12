locals {
  # Platform-utility names read ROLE-then-SCOPE (clouddeploy-europe-west3),
  # mirroring the workload class (mattermost-europe-west3).
  exec_sa_id = "clouddeploy-${var.region}"
  # No "-pipeline" type suffix: it is THE delivery pipeline, named after the
  # region alone (mirroring the GKE cluster / Cloud SQL instance).
  pipeline_name = var.region

  # Targets keyed by stage name (order-independent); the pipeline below drives
  # the promotion order from the ordered var.stages list.
  targets = { for s in var.stages : s.name => s }
}

# The Cloud Deploy service agent is created lazily on first API use, so a fresh
# project has none when the IAM binding below runs -> "service-...@gcp-sa-
# clouddeploy... does not exist". Force it into existence up front and reference
# its email so the act-as binding is ordered strictly after the agent exists.
resource "google_project_service_identity" "clouddeploy" {
  provider = google-beta

  project = var.project_id
  service = "clouddeploy.googleapis.com"
}

# Execution identity Cloud Deploy uses to render and deploy.
resource "google_service_account" "exec" {
  project      = var.project_id
  account_id   = local.exec_sa_id
  display_name = "Cloud Deploy execution SA"
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
  member             = "serviceAccount:${google_project_service_identity.clouddeploy.email}"
}

# One target per stage. Every target points at the SAME cluster; the deploy
# namespace and per-env config diverge via the Skaffold profile bound to the
# stage in the pipeline below. `require_approval` and the post-deploy VERIFY
# execution usage are per stage.
resource "google_clouddeploy_target" "stage" {
  for_each = local.targets

  project  = var.project_id
  location = var.region
  name     = "${each.value.name}-${var.region}"

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
