variable "project_id" {
  type        = string
  description = "Former project that stored the legacy billing account export."
}

variable "billing_account_id" {
  type        = string
  description = "Former Cloud Billing account ID."
}

variable "dataset_id" {
  type        = string
  description = "BigQuery dataset used by the former billing export."
  default     = "billing"
}

variable "location" {
  type        = string
  description = "BigQuery dataset location."
  default     = "EU"
}

variable "reader_member" {
  type        = string
  description = "Identity that previously read the legacy billing dataset."
}

variable "labels" {
  type        = map(string)
  description = "Labels formerly applied to the dataset."
  default     = {}
}
