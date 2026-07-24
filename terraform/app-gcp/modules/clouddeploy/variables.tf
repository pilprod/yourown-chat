variable "project_id" {
  type        = string
  description = "Project the delivery pipeline and targets live in."
}

variable "region" {
  type        = string
  description = "Region for the delivery pipeline and targets."
}

variable "pipeline_name" {
  type        = string
  description = "Component delivery pipeline name, for example mattermost or mcp."
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
    name               = string
    profiles           = optional(list(string), [])
    require_approval   = optional(bool, false)
    verify             = optional(bool, false)
    predeploy_actions  = optional(list(string), [])
    postdeploy_actions = optional(list(string), [])
  }))
  description = "Ordered promotion stages. Each becomes one Cloud Deploy target on the shared cluster; list order defines the dev -> prod promotion flow. Per stage: `profiles` renders the stage, `require_approval` gates entry, `predeploy_actions` run after approval but before deploy, `verify` runs post-deploy verification, and `postdeploy_actions` run last."

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

variable "deploy_parameters" {
  type        = map(string)
  description = "Key => value map injected into every stage's Skaffold render. A manifest field annotated `# from-param: $${key}` has its value replaced on each release -- the Terraform-owned values (bucket, Workload Identity emails) flow into Kubernetes without hand-edited markers. Note: substitution replaces the WHOLE field value; partial interpolation inside a string is not supported."
  default     = {}
}
