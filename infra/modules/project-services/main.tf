# Enable one API per resource so the dependency graph is explicit and a single
# failing API does not tear down the others.
resource "google_project_service" "this" {
  for_each = toset(var.activate_apis)

  project = var.project_id
  service = each.value

  disable_on_destroy         = var.disable_services_on_destroy
  disable_dependent_services = var.disable_dependent_services
}
