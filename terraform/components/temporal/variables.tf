variable "enabled" {
  type    = bool
  default = false
}

variable "project_id" { type = string }
variable "region" { type = string }
variable "cloudsql_instance_name" { type = string }
variable "cloudsql_private_ip" { type = string }
variable "kms_key_name" { type = string }
variable "activity_worker_member" { type = string }

variable "chart_version" {
  type    = string
  default = "1.2.0"
}

variable "namespace" {
  type    = string
  default = "temporal"
}

variable "password_rotation" {
  type    = string
  default = "1"
}

variable "results_retention_days" {
  type    = number
  default = 30
}

variable "labels" {
  type    = map(string)
  default = {}
}
