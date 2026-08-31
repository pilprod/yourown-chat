variable "project_id" {
  type        = string
  description = "Existing GCP project whose Cloud Build jobs must use explicitly selected service accounts."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "policy_admin_member" {
  type        = string
  description = "Existing Terraform apply principal granted only the permissions required to manage these two project policies."

  validation {
    condition     = can(regex("^(serviceAccount|principal|principalSet):.+$", var.policy_admin_member))
    error_message = "policy_admin_member must be an IAM serviceAccount, principal or principalSet member string."
  }
}
