variable "namespace" {
  type        = string
  description = "Namespace the dev-tenant Role/RoleBinding live in."
  default     = "dev"
}

variable "subjects" {
  type = list(object({
    kind = string # "Group" or "User"
    name = string
  }))
  description = "Dev-team RBAC subjects (Google Group or individual Users). Empty (default) creates no RBAC. A Group subject requires 'Google Groups for GKE RBAC' on the cluster."
  default     = []

  validation {
    condition     = alltrue([for s in var.subjects : contains(["Group", "User"], s.kind)])
    error_message = "Each subject kind must be Group or User."
  }
}
