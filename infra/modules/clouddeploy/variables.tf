variable "project_id" {
  type        = string
  description = "Project the pipeline and target live in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for Cloud Deploy resource names, e.g. 'ycs-dev'."
}

variable "region" {
  type        = string
  description = "Region for the delivery pipeline and target."
}

variable "gke_cluster_id" {
  type        = string
  description = "Target GKE cluster ID: projects/<p>/locations/<l>/clusters/<n>."

  validation {
    condition     = can(regex("^projects/.+/locations/.+/clusters/.+$", var.gke_cluster_id))
    error_message = "gke_cluster_id must be a fully-qualified cluster resource ID."
  }
}

variable "target_name" {
  type        = string
  description = "Cloud Deploy target name (typically the environment)."
  default     = "gke"
}

variable "require_approval" {
  type        = bool
  description = "Require manual approval before promoting to this target."
  default     = false
}

variable "execution_sa_roles" {
  type        = list(string)
  description = "Project roles granted to the Cloud Deploy execution SA."
  default = [
    "roles/clouddeploy.jobRunner",
    "roles/container.developer",
    "roles/logging.logWriter",
    "roles/storage.objectUser",
    "roles/artifactregistry.reader",
  ]
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to Cloud Deploy resources."
  default     = {}
}
