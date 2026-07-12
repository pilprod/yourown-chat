locals {
  # Name = ACTUAL footprint. Regional singletons are named after the region
  # alone (europe-west3): the project is already yourown-chat and each is the
  # ONLY object of its GCP type in the region, so no "-subnet/-router/-nat"
  # type suffix is needed and the region tag still keeps a second deployment
  # from colliding (names are unique per resource type, so a subnet, router
  # and NAT may all read europe-west3).
  #
  # NON-singleton platform utilities read ROLE-then-SCOPE (ingress-europe-west3),
  # mirroring the workload class (mattermost-europe-west3): the role leads, the
  # footprint disambiguates. EXCEPTION: the two secondary ranges stay
  # ${region}-pods/-services -- they are not standalone resources but fields of
  # the subnet, and renaming them REPLACES the subnet (and the live cluster on
  # it), which is never worth a cosmetic flip.
  #
  # GLOBAL objects carry no region -- a region tag would lie about their
  # footprint. Their names reduce to the bare role: the VPC is the project's
  # sole network -> "vpc" (mirroring the crypto key "cmek"); the VPC-wide
  # firewall -> "allow-internal"; the PSA peering range -> "psa". (The VPC's
  # routing_mode is REGIONAL and its one subnet is single-region, but the
  # OBJECT itself is global -- a second region would reuse this same VPC with
  # another subnet, not create a sibling.)
  network_name           = "vpc"
  subnet_name            = var.region
  pods_range_name        = "${var.region}-pods"
  services_range_name    = "${var.region}-services"
  router_name            = var.region
  nat_name               = var.region
  psa_range_name         = "psa"
  internal_firewall_name = "allow-internal"
  ingress_ip_name        = "ingress-${var.region}"
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

# ---------------------------------------------------------------------------
# Reserved regional external IP ("white address") for the public ingress LB.
# Only created when var.ingress_static_ip = true (prod). The ingress-nginx
# Service pins its loadBalancerIP to this address, and admits ONLY Cloudflare
# source ranges via loadBalancerSourceRanges (see platform/ingress-nginx). The
# address stays stable across LB re-creations so the Cloudflare DNS record is
# never orphaned. Reserved IPs attached to a forwarding rule are not billed.
# ---------------------------------------------------------------------------
resource "google_compute_address" "ingress" {
  count = var.ingress_static_ip ? 1 : 0

  project      = var.project_id
  name         = local.ingress_ip_name
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = var.labels
}
