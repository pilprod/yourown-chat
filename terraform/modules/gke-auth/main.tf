# Resolve the platform cluster's endpoint + CA from its published resource ID
# and mint a short-lived bearer token, so the stack-level helm provider can
# talk to the Kubernetes API. Read-only: this module owns no resources.

locals {
  # gke_cluster_id arrives as the full resource ID the platform stack
  # publishes: projects/<project>/locations/<location>/clusters/<name>.
  cluster = regex("^projects/(?P<project>[^/]+)/locations/(?P<location>[^/]+)/clusters/(?P<name>.+)$", var.gke_cluster_id)
}

data "google_container_cluster" "this" {
  project  = local.cluster.project
  location = local.cluster.location
  name     = local.cluster.name
}

# Access token for the identity the google provider runs as (the impersonated
# terraform-apply@ SA, which already holds roles/container.admin => Kubernetes
# cluster-admin). Short-lived (<= 1h) -- it only needs to outlive the helm
# operations of a single run.
data "google_client_config" "this" {}
