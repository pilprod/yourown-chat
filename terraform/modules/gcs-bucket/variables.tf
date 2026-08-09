variable "project_id" { type = string }
variable "name" { type = string }
variable "location" { type = string }

variable "kms_key_name" {
  type    = string
  default = null
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "retention_days" {
  type    = number
  default = 30
}

variable "members" {
  type    = set(string)
  default = []
}

variable "member_role" {
  type    = string
  default = "roles/storage.objectUser"
}

variable "force_destroy" {
  type    = bool
  default = false
}
