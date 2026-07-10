output "project_id" {
  description = "Project ID, re-exported so downstream modules can depend on API enablement explicitly."
  value       = var.project_id
  # Force consumers that read this output to wait for all APIs to be enabled.
  depends_on = [google_project_service.this]
}

output "enabled_apis" {
  description = "The set of APIs enabled by this module."
  value       = keys(google_project_service.this)
}
