output "repository_id" {
  description = "Artifact Registry repository ID (short name)."
  value       = google_artifact_registry_repository.this.repository_id
}

output "repository_name" {
  description = "Fully-qualified repository resource name."
  value       = google_artifact_registry_repository.this.id
}

output "location" {
  description = "Repository location."
  value       = google_artifact_registry_repository.this.location
}

output "registry_host" {
  description = "Docker registry host, e.g. europe-west3-docker.pkg.dev."
  value       = local.registry_host
}

output "repository_path" {
  description = "Full image path prefix: HOST/PROJECT/REPO."
  value       = local.repository_path
}
