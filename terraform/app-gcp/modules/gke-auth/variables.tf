variable "gke_cluster_id" {
  type        = string
  description = "Full GKE cluster resource ID (projects/<p>/locations/<l>/clusters/<n>). Published by the platform stack (upstream_input.platform.gke_cluster_id)."

  validation {
    condition     = can(regex("^projects/[^/]+/locations/[^/]+/clusters/.+$", var.gke_cluster_id))
    error_message = "gke_cluster_id must be a full resource ID: projects/<p>/locations/<l>/clusters/<n>."
  }
}
