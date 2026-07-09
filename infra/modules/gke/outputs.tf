output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.this.name
}

output "cluster_id" {
  description = "Fully-qualified cluster ID."
  value       = google_container_cluster.this.id
}

output "location" {
  description = "Cluster location (zone or region)."
  value       = google_container_cluster.this.location
}

output "endpoint" {
  description = "Control-plane endpoint."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64 cluster CA certificate."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "node_service_account_email" {
  description = "Email of the least-privilege node service account."
  value       = google_service_account.node.email
}

output "node_pool_names" {
  description = "Map of node pool key => actual node pool name."
  value       = { for k, p in google_container_node_pool.pool : k => p.name }
}

output "workload_identity_pool" {
  description = "Workload Identity pool for KSA <-> GSA binding."
  value       = local.workload_pool
}
