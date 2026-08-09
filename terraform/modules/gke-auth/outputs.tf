output "host" {
  description = "Cluster API endpoint URL for the helm provider."
  value       = "https://${data.google_container_cluster.this.endpoint}"
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "PEM cluster CA certificate (decoded) for the helm provider."
  value       = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  sensitive   = true
}

output "access_token" {
  description = "Short-lived (<= 1h) OAuth2 access token of the impersonated apply SA; bearer token for the helm provider."
  value       = data.google_client_config.this.access_token
  sensitive   = true
}
