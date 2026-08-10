# Resolve the platform-owned cluster's endpoint + CA and mint a short-lived
# bearer token for this Stack's official-service Helm provider. This module is
# data-only and owns no GKE resources.

locals {
  cluster = regex("^projects/(?P<project>[^/]+)/locations/(?P<location>[^/]+)/clusters/(?P<name>.+)$", var.gke_cluster_id)
}

data "google_container_cluster" "this" {
  project  = local.cluster.project
  location = local.cluster.location
  name     = local.cluster.name
}

data "google_client_config" "this" {}
