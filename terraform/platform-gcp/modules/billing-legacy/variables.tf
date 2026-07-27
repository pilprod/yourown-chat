variable "project_id" {
  type        = string
  description = "Existing dedicated project that stores the legacy billing account export."
}

variable "billing_account_id" {
  type        = string
  description = "Legacy Cloud Billing account used to derive the managed export table name."
}

variable "dataset_id" {
  type        = string
  description = "BigQuery dataset selected in the legacy account's Billing export settings."
  default     = "billing"
}

variable "location" {
  type        = string
  description = "EU multi-region enables previous-month backfill on first export enablement."
  default     = "EU"
}

variable "reader_member" {
  type        = string
  description = "Production MCP identity allowed to read the legacy billing dataset."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the FinOps project and dataset."
  default     = {}
}
