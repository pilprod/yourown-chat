variable "project_id" {
  type        = string
  description = "Project the secrets live in."
}

variable "secret_ids" {
  type        = map(string)
  description = "Map of logical name => Secret Manager secret_id whose latest enabled version to read."
}
