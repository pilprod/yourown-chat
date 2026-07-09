variable "project_id" {
  type        = string
  description = "Project the Cloud Build identity lives in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for Cloud Build resource names, e.g. 'ycs-dev'."
}

variable "artifact_registry_location" {
  type        = string
  description = "Location of the Artifact Registry repo images are pushed to."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry repository ID the build SA may push to (repo-scoped writer)."
}

variable "grant_clouddeploy_releaser" {
  type        = bool
  description = "Grant the build SA permission to create Cloud Deploy releases (project-scoped)."
  default     = true
}

variable "clouddeploy_execution_sa_email" {
  type        = string
  description = "Cloud Deploy execution SA the build must actAs when cutting a release. Null to skip."
  default     = null
}

variable "additional_project_roles" {
  type        = list(string)
  description = "Extra project-level roles for the build SA (keep minimal)."
  default     = []
}
