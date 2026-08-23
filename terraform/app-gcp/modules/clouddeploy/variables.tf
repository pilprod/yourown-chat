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
    target_name        = optional(string)
    profiles           = optional(list(string), [])
    require_approval   = optional(bool, false)
    verify             = optional(bool, false)
    predeploy_actions  = optional(list(string), [])
    postdeploy_actions = optional(list(string), [])
  }))
  description = "Ordered promotion stages. Each becomes one Cloud Deploy target on the shared cluster; list order defines the dev -> prod promotion flow. `target_name` optionally overrides the default <pipeline>-<stage> resource name. Per stage: `profiles` renders the stage, `require_approval` gates entry, `predeploy_actions` run in Cloud Build after approval but before deploy, `verify` runs post-deploy verification, and `postdeploy_actions` run last."

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

variable "cleanup_sa_roles" {
  type        = list(string)
  description = "Project roles for the dedicated PREDEPLOY cleanup SA. Kubernetes mutation remains restricted separately by namespace RoleBindings."
  default = [
    "roles/clouddeploy.jobRunner",
    "roles/container.clusterViewer",
    "roles/logging.logWriter",
    "roles/storage.objectUser",
  ]
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

variable "release_manager_members" {
  type        = set(string)
  description = "Narrowly scoped principals allowed to promote existing releases and therefore impersonate the target execution identities. Cloud Deploy API permissions are granted separately."
  default     = []

  validation {
    condition = alltrue([
      for member in var.release_manager_members :
      can(regex("^(serviceAccount|user|group):.+$", member))
    ])
    error_message = "release_manager_members entries must be IAM member strings."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to Cloud Deploy resources."
  default     = {}
}

variable "deploy_parameters" {
  type        = map(string)
  description = "Key => value map injected into every stage's Skaffold render. Skaffold passes these to authored Helm charts as --set values (consumed through .Values); raw manifests use `# from-param: $${key}` post-render directives. Terraform-owned values such as buckets and Workload Identity emails therefore flow into Kubernetes without placeholder resources."
  default     = {}
}
