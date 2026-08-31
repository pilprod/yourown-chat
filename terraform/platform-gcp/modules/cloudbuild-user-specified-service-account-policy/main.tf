locals {
  project_parent = "projects/${var.project_id}"
  cloudbuild_service_account_constraints = toset([
    "constraints/cloudbuild.useBuildServiceAccount",
    "constraints/cloudbuild.useComputeServiceAccount",
  ])
}

# GCP does not allow orgpolicy.policies.create in a custom role. Bind the
# supported predefined role at this project only, then order policy writes
# after the binding so the first apply can bootstrap itself without Owner.
resource "google_project_iam_member" "policy_manager" {
  project = var.project_id
  role    = "roles/orgpolicy.policyAdmin"
  member  = var.policy_admin_member
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

  depends_on = [google_project_iam_member.policy_manager]
}
