locals {
  project_parent = "projects/${var.project_id}"
  cloudbuild_service_account_constraints = toset([
    "constraints/cloudbuild.useBuildServiceAccount",
    "constraints/cloudbuild.useComputeServiceAccount",
  ])
}

# The Stack apply identity already owns project IAM and custom-role management,
# but intentionally has no broad Organization Policy role. Give it only the
# project-level permissions this module needs, then order policy writes after
# the binding so the first apply can bootstrap itself without an Owner grant.
resource "google_project_iam_custom_role" "policy_manager" {
  project     = var.project_id
  role_id     = "cloudBuildPolicyManager"
  title       = "Cloud Build policy manager"
  description = "Manage project Cloud Build service-account constraints only through reviewed Terraform."
  permissions = [
    "orgpolicy.constraints.list",
    "orgpolicy.policies.create",
    "orgpolicy.policies.delete",
    "orgpolicy.policies.list",
    "orgpolicy.policies.update",
    "orgpolicy.policy.get",
    "orgpolicy.policy.set",
  ]
}

resource "google_project_iam_member" "policy_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.policy_manager.name
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
