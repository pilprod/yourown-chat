variable "project_id" {
  type        = string
  description = "Project that owns the billing export dataset."
}

variable "billing_account_id" {
  type        = string
  description = "Billing account ID used by Google in the generated detailed export table name."
}

variable "dataset_id" {
  type        = string
  description = "BigQuery dataset ID selected in Cloud Billing export settings."
  default     = "billing"
}

variable "location" {
  type        = string
  description = "BigQuery dataset location. EU provides previous-month backfill on first enablement."
  default     = "EU"
}

variable "reader_member" {
  type        = string
  description = "IAM member allowed to query detailed billing rows."
}

variable "manager_member" {
  type        = string
  description = "Terraform apply identity granted permission to create this dataset."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the billing export dataset."
  default     = {}
}
