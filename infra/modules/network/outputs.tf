output "network_id" {
  description = "Fully-qualified VPC network ID."
  value       = google_compute_network.this.id
}

output "network_self_link" {
  description = "Self link of the VPC network."
  value       = google_compute_network.this.self_link
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.this.name
}

output "subnet_id" {
  description = "Fully-qualified subnet ID."
  value       = google_compute_subnetwork.this.id
}

output "subnet_self_link" {
  description = "Self link of the subnet."
  value       = google_compute_subnetwork.this.self_link
}

output "subnet_name" {
  description = "Name of the subnet."
  value       = google_compute_subnetwork.this.name
}

output "pods_range_name" {
  description = "Secondary range name for GKE Pods."
  value       = local.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for GKE Services."
  value       = local.services_range_name
}

output "private_service_connection_id" {
  description = "PSA service networking connection ID; depend on this before creating private-IP managed services."
  value       = google_service_networking_connection.psa.id
}
