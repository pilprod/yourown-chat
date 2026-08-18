variable "project_id" { type = string }
variable "location" { type = string }
variable "secret_id" { type = string }
variable "kms_key_name" { type = string }
variable "labels" { type = map(string) }
variable "accessor_members" { type = set(string) }

variable "password_version" {
  type        = number
  description = "Write-only rotation marker. Increment only when intentionally replacing the temporary bootstrap password."
}
