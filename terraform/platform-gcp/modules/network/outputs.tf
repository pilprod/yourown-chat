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

output "services_cidr" {
  description = "Secondary IPv4 range for GKE Services; the cluster DNS service uses host 10."
  value       = var.services_cidr
}

output "private_service_connection_id" {
  description = "PSA service networking connection ID; depend on this before creating private-IP managed services."
  value       = google_service_networking_connection.psa.id
}

output "ingress_ip_address" {
  description = "Reserved regional external IP for the public ingress LB (null when ingress_static_ip = false). Point the Cloudflare A record at this address."
  value       = one(google_compute_address.ingress[*].address)
}

output "calls_ip_address" {
  description = "Reserved regional external IP used by Mattermost RTCD TCP/UDP media load balancers."
  value       = one(google_compute_address.calls[*].address)
}

output "agentgateway_ip_address" {
  description = "Dedicated regional external IP for the direct agentgateway/Broker data plane."
  value       = one(google_compute_address.agentgateway[*].address)
}

output "agentgateway_ip_name" {
  description = "GCP regional address resource name consumed by the GKE L4 RBS Service annotation."
  value       = one(google_compute_address.agentgateway[*].name)
}

output "nat_egress_ip_address" {
  description = "Reserved regional external IP used by Cloud NAT for stable outbound allowlists such as Google Workspace SMTP Relay."
  value       = google_compute_address.nat.address
}
