variable "project_id" {
  type        = string
  description = "Project the delivery pipeline and targets live in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for Cloud Deploy resource names (pipeline, targets, execution SA), e.g. 'yourown-chat'. The pipeline spans every stage, so use a tier-neutral prefix rather than an environment-scoped one."
}

variable "region" {
  type        = string
  description = "Region for the delivery pipeline and targets."
}

variable "gke_cluster_id" {
  type        = string
  description = "GKE cluster ID shared by every stage: projects/<p>/locations/<l>/clusters/<n>. Per-stage divergence (namespace, env) is handled by the Skaffold profile, not a separate cluster."

  validation {
    condition     = can(regex("^projects/.+/locations/.+/clusters/.+$", var.gke_cluster_id))
    error_message = "gke_cluster_id must be a fully-qualified cluster resource ID."
  }
}

variable "stages" {
  type = list(object({
    name             = string
    profiles         = optional(list(string), [])
    require_approval = optional(bool, false)
    verify           = optional(bool, false)
  }))
  description = "Ordered promotion stages. Each becomes one Cloud Deploy target on the shared cluster; list order defines the dev -> prod promotion flow. Per stage: `profiles` = Skaffold profile(s) that render this stage's namespace/env; `require_approval` gates promotion into the stage; `verify` runs the Skaffold verify tests post-deploy (and adds the VERIFY execution usage to the target)."

  default = [
    { name = "dev", profiles = ["dev"], require_approval = false, verify = true },
    { name = "prod", profiles = ["prod"], require_approval = true, verify = false },
  ]

  validation {
    condition     = length(var.stages) > 0
    error_message = "Provide at least one delivery stage."
  }

  validation {
    condition     = length(distinct([for s in var.stages : s.name])) == length(var.stages)
    error_message = "Stage names must be unique (they key the Cloud Deploy targets)."
  }
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
