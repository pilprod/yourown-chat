output "host" {
  description = "Cluster API endpoint URL for the Helm provider."
  value       = "https://${data.google_container_cluster.this.endpoint}"
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Decoded cluster CA certificate for the Helm provider."
  value       = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  sensitive   = true
}

output "access_token" {
  description = "Short-lived OAuth2 bearer token for the Helm provider."
  value       = data.google_client_config.this.access_token
  sensitive   = true
}
