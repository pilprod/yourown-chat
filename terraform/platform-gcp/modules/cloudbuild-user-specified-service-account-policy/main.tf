locals {
  project_parent = "projects/${var.project_id}"
  cloudbuild_service_account_constraints = toset([
    "constraints/cloudbuild.useBuildServiceAccount",
    "constraints/cloudbuild.useComputeServiceAccount",
  ])
}

resource "google_org_policy_policy" "cloudbuild_user_specified_service_account" {
  for_each = local.cloudbuild_service_account_constraints

  name   = "${local.project_parent}/policies/${trimprefix(each.value, "constraints/")}"
  parent = local.project_parent

  spec {
    inherit_from_parent = false

    rules {
      enforce = "FALSE"
    }
  }
}
