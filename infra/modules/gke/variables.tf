variable "project_id" {
  type        = string
  description = "Project the cluster is created in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for cluster resource names, e.g. 'ycs-dev'."
}

variable "location" {
  type        = string
  description = "Cluster location. A zone (e.g. europe-west3-b) = cheapest zonal cluster; a region (e.g. europe-west3) = regional/HA control plane."
}

variable "network_id" {
  type        = string
  description = "VPC network self link or ID to attach the cluster to."
}

variable "subnet_id" {
  type        = string
  description = "Subnet self link or ID for the cluster nodes."
}

variable "pods_range_name" {
  type        = string
  description = "Secondary range name used for Pods."
}

variable "services_range_name" {
  type        = string
  description = "Secondary range name used for Services."
}

variable "release_channel" {
  type        = string
  description = "GKE release channel."
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "EXTENDED"], var.release_channel)
    error_message = "release_channel must be one of RAPID, REGULAR, STABLE, EXTENDED."
  }
}

variable "master_ipv4_cidr_block" {
  type        = string
  description = "RFC1918 /28 block for the private control plane."
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.master_ipv4_cidr_block, 0)) && tonumber(split("/", var.master_ipv4_cidr_block)[1]) == 28
    error_message = "master_ipv4_cidr_block must be a valid /28 CIDR."
  }
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "CIDRs allowed to reach the public control-plane endpoint. Nodes are always private. Empty = only Google-internal access."
  default     = []
}

variable "node_pools" {
  type = map(object({
    machine_type = optional(string, "e2-small")
    spot         = optional(bool, true)
    min_count    = optional(number, 1)
    max_count    = optional(number, 2)
    disk_size_gb = optional(number, 30)
    disk_type    = optional(string, "pd-standard")
    labels       = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  description = "Map of node pool name => spec. Use taints/labels to isolate workload tiers (e.g. prod vs dev) on one cluster."
  default     = { primary = {} }

  validation {
    condition     = length(var.node_pools) > 0
    error_message = "At least one node pool is required."
  }

  validation {
    condition = alltrue(flatten([
      for _, p in var.node_pools : [
        for t in p.taints : contains(["NO_SCHEDULE", "PREFER_NO_SCHEDULE", "NO_EXECUTE"], t.effect)
      ]
    ]))
    error_message = "taint effect must be NO_SCHEDULE, PREFER_NO_SCHEDULE or NO_EXECUTE."
  }

  validation {
    condition = alltrue([
      for _, p in var.node_pools : contains(["pd-standard", "pd-balanced", "pd-ssd"], p.disk_type)
    ])
    error_message = "disk_type must be pd-standard, pd-balanced or pd-ssd."
  }

  validation {
    condition = alltrue([
      for _, p in var.node_pools : p.max_count >= p.min_count && p.disk_size_gb >= 20
    ])
    error_message = "Each pool needs max_count >= min_count and disk_size_gb >= 20."
  }
}

variable "enable_secret_manager_csi" {
  type        = bool
  description = "Enable the GKE Secret Manager add-on (CSI) so pods can mount Secret Manager secrets via Workload Identity."
  default     = true
}

variable "enable_dataplane_v2" {
  type        = bool
  description = "Use Dataplane V2 (eBPF) datapath with built-in network policy. No extra cost, recommended."
  default     = true
}

variable "logging_components" {
  type        = list(string)
  description = "Logging components to enable. Keep to SYSTEM_COMPONENTS for lowest cost."
  default     = ["SYSTEM_COMPONENTS"]
}

variable "monitoring_components" {
  type        = list(string)
  description = "Monitoring components to enable."
  default     = ["SYSTEM_COMPONENTS"]
}

variable "enable_managed_prometheus" {
  type        = bool
  description = "Enable Google Managed Prometheus (adds cost)."
  default     = false
}

variable "maintenance_start_time" {
  type        = string
  description = "Daily maintenance window start (RFC3339 time, UTC)."
  default     = "2025-01-01T02:00:00Z"
}

variable "deletion_protection" {
  type        = bool
  description = "Protect the cluster from accidental deletion."
  default     = true
}

variable "resource_labels" {
  type        = map(string)
  description = "Labels applied to the cluster and nodes."
  default     = {}
}
