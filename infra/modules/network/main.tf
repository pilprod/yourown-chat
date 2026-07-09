locals {
  network_name           = "${var.name_prefix}-vpc"
  subnet_name            = "${var.name_prefix}-${var.region}-subnet"
  pods_range_name        = "${var.name_prefix}-pods"
  services_range_name    = "${var.name_prefix}-services"
  router_name            = "${var.name_prefix}-router"
  nat_name               = "${var.name_prefix}-nat"
  psa_range_name         = "${var.name_prefix}-psa"
  internal_firewall_name = "${var.name_prefix}-allow-internal"
}

# Custom-mode VPC: no auto subnets so ranges are explicit and predictable.
resource "google_compute_network" "this" {
  project                         = var.project_id
  name                            = local.network_name
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "this" {
  project       = var.project_id
  name          = local.subnet_name
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.subnet_cidr

  # Required for private nodes to reach Google APIs without external IPs.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = var.services_cidr
  }

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# Cloud Router + NAT provide egress for private (no external IP) GKE nodes.
resource "google_compute_router" "this" {
  project = var.project_id
  name    = local.router_name
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  project                            = var.project_id
  name                               = local.nat_name
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  min_ports_per_vm                   = var.nat_min_ports_per_vm

  dynamic "log_config" {
    for_each = var.nat_log_filter == "" ? [] : [1]
    content {
      enable = true
      filter = var.nat_log_filter
    }
  }
}

# Baseline east-west rule: allow traffic between all ranges attached to the VPC.
resource "google_compute_firewall" "allow_internal" {
  project   = var.project_id
  name      = local.internal_firewall_name
  network   = google_compute_network.this.id
  direction = "INGRESS"
  priority  = 65534

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}

# ---------------------------------------------------------------------------
# Private Service Access: reserved range + peering so managed services such as
# Cloud SQL can be reached over private IP from this VPC.
# ---------------------------------------------------------------------------
resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = local.psa_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_prefix_length
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}
