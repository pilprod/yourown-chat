variable "gke_cluster_id" {
  type        = string
  description = "Full GKE resource ID published by platform-gcp."

  validation {
    condition     = can(regex("^projects/[^/]+/locations/[^/]+/clusters/.+$", var.gke_cluster_id))
    error_message = "gke_cluster_id must be projects/<p>/locations/<l>/clusters/<n>."
  }
}
