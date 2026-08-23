variable "mattermost_operator_chart_version" {
  type        = string
  description = "mattermost/mattermost-operator chart version to install."
}

variable "ingress_nginx_chart_version" {
  type        = string
  description = "ingress-nginx/ingress-nginx chart version to install."
}

variable "ingress_load_balancer_ip" {
  type        = string
  description = "Reserved regional external IP to pin the ingress-nginx Service to (the platform's published ingress_ip_address). null skips the ingress-nginx release."
  default     = null
}

variable "adopt_existing_releases" {
  type        = bool
  description = "Import bootstrap Helm releases that already exist in the cluster but are missing from Terraform state."
  default     = false
}

variable "kagent_testbed_enabled" {
  type        = bool
  description = "Install the pinned kagent testbed releases."
  default     = false
}

variable "kagent_system_namespace" {
  type        = string
  description = "Namespace for the kagent application and CRD Helm releases."
  default     = "kagent-system"
}

variable "kagent_chart_repository" {
  type        = string
  description = "OCI repository containing the kagent and kagent-crds charts."
}

variable "kagent_chart_version" {
  type        = string
  description = "Pinned version shared by the kagent application and CRD charts."
}

variable "kagent_source_commit" {
  type        = string
  description = "Reviewed source commit corresponding to the pinned release."

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.kagent_source_commit))
    error_message = "kagent_source_commit must be a lowercase 40-character Git commit."
  }
}

variable "kagent_chart_oci_digest" {
  type        = string
  description = "Reviewed application chart OCI manifest digest."

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.kagent_chart_oci_digest))
    error_message = "kagent_chart_oci_digest must be a sha256 OCI digest."
  }
}

variable "kagent_crds_chart_oci_digest" {
  type        = string
  description = "Reviewed CRD chart OCI manifest digest."

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.kagent_crds_chart_oci_digest))
    error_message = "kagent_crds_chart_oci_digest must be a sha256 OCI digest."
  }
}
