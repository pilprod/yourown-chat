variable "project_id" {
  type        = string
  description = "Project the instance is created in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for Cloud SQL resource names, e.g. 'yourown-chat-dev'."
}

variable "region" {
  type        = string
  description = "Region for the instance."
}

variable "network_id" {
  type        = string
  description = "VPC network self link/ID used for the private IP connection."
}

variable "private_service_connection_id" {
  type        = string
  description = "PSA connection ID to depend on before creating the private-IP instance."
}

variable "database_version" {
  type        = string
  description = "Cloud SQL PostgreSQL engine version."
  default     = "POSTGRES_16"

  validation {
    condition     = startswith(var.database_version, "POSTGRES_")
    error_message = "Only PostgreSQL engine versions are supported by this module."
  }
}

variable "tier" {
  type        = string
  description = "Machine tier. db-f1-micro is the cheapest (shared core)."
  default     = "db-f1-micro"
}

variable "edition" {
  type        = string
  description = "Cloud SQL edition. Shared-core tiers require ENTERPRISE."
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.edition)
    error_message = "edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

variable "availability_type" {
  type        = string
  description = "ZONAL (cheapest) or REGIONAL (HA)."
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be ZONAL or REGIONAL."
  }
}

variable "disk_size_gb" {
  type        = number
  description = "Initial data disk size in GB."
  default     = 10

  validation {
    condition     = var.disk_size_gb >= 10
    error_message = "disk_size_gb must be >= 10."
  }
}

variable "disk_type" {
  type        = string
  description = "PD_SSD or PD_HDD (HDD is cheaper for small/low-IOPS workloads)."
  default     = "PD_SSD"

  validation {
    condition     = contains(["PD_SSD", "PD_HDD"], var.disk_type)
    error_message = "disk_type must be PD_SSD or PD_HDD."
  }
}

variable "disk_autoresize" {
  type        = bool
  description = "Automatically grow the disk when near full."
  default     = true
}

variable "backup_enabled" {
  type        = bool
  description = "Enable automated backups."
  default     = true
}

variable "backup_start_time" {
  type        = string
  description = "Backup window start (HH:MM UTC)."
  default     = "03:00"
}

variable "point_in_time_recovery_enabled" {
  type        = bool
  description = "Enable PITR (WAL archiving). Adds storage cost; off by default for the cheapest footprint."
  default     = false
}

variable "backup_retained_count" {
  type        = number
  description = "Number of automated backups to retain."
  default     = 7
}

variable "transaction_log_retention_days" {
  type        = number
  description = "Days of transaction logs retained for PITR."
  default     = 7
}

variable "database_name" {
  type        = string
  description = "Application database to create."
  default     = "app"
}

variable "db_user_name" {
  type        = string
  description = "Application database user to create."
  default     = "app"
}

variable "database_flags" {
  type        = map(string)
  description = "Optional database flags, e.g. { max_connections = \"100\" }."
  default     = {}
}

variable "deletion_protection" {
  type        = bool
  description = "Protect the instance from deletion (Terraform + Cloud SQL API)."
  default     = true
}

variable "create_connection_secret" {
  type        = bool
  description = "Also publish a ready-to-use postgres:// connection URI to Secret Manager."
  default     = false
}

variable "password_secret_accessors" {
  type        = list(string)
  description = "IAM members granted secretAccessor on the DB password secret (e.g. Workload Identity SAs)."
  default     = []
}

variable "connection_secret_accessors" {
  type        = list(string)
  description = "IAM members granted secretAccessor on the connection URI secret."
  default     = []
}

variable "user_labels" {
  type        = map(string)
  description = "Labels applied to the instance."
  default     = {}
}

variable "encryption_key_name" {
  type        = string
  description = "Optional CMEK key (full resource ID) for disk encryption. Null = Google-managed keys. The key must be in the same region as the instance, and the Cloud SQL service agent must hold cryptoKeyEncrypterDecrypter on it BEFORE the instance is created. Immutable for the life of the instance (changing it forces a replacement)."
  default     = null
}
