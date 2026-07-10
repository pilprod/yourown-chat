variable "project_id" {
  type        = string
  description = "Project the network is created in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all network resource names, e.g. 'yourown-chat-dev'."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/hyphen, starting with a letter, <= 21 chars."
  }
}

variable "region" {
  type        = string
  description = "Region for the subnet, Cloud Router and Cloud NAT."
}

variable "subnet_cidr" {
  type        = string
  description = "Primary CIDR range for the GKE nodes subnet."
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "pods_cidr" {
  type        = string
  description = "Secondary range for GKE Pods."
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a valid IPv4 CIDR."
  }
}

variable "services_cidr" {
  type        = string
  description = "Secondary range for GKE Services."
  default     = "10.30.0.0/20"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a valid IPv4 CIDR."
  }
}

variable "psa_prefix_length" {
  type        = number
  description = "Prefix length of the address block reserved for Private Service Access (CloudSQL, etc.)."
  default     = 20

  validation {
    condition     = var.psa_prefix_length >= 16 && var.psa_prefix_length <= 24
    error_message = "psa_prefix_length must be between 16 and 24."
  }
}

variable "enable_flow_logs" {
  type        = bool
  description = "Enable VPC flow logs on the subnet (adds cost; useful for audit/security)."
  default     = false
}

variable "ingress_static_ip" {
  type        = bool
  description = "Reserve a regional external static IP for the public ingress load balancer (the Cloudflare-facing 'white address'). Enable only for environments with a public ingress (e.g. prod)."
  default     = false
}

variable "nat_min_ports_per_vm" {
  type        = number
  description = "Minimum NAT source ports per VM."
  default     = 64
}

variable "nat_log_filter" {
  type        = string
  description = "Cloud NAT logging filter: ERRORS_ONLY, TRANSLATIONS_ONLY, or ALL. Empty string disables logging."
  default     = "ERRORS_ONLY"

  validation {
    condition     = contains(["", "ERRORS_ONLY", "TRANSLATIONS_ONLY", "ALL"], var.nat_log_filter)
    error_message = "nat_log_filter must be one of \"\", ERRORS_ONLY, TRANSLATIONS_ONLY, ALL."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to labellable network resources."
  default     = {}
}
