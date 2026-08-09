variable "project_id" { type = string }
variable "instance_name" { type = string }
variable "database_names" { type = set(string) }
variable "user_name" { type = string }
variable "password_secret_id" { type = string }
variable "secret_location" { type = string }

variable "kms_key_name" {
  type    = string
  default = null
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "password_rotation" {
  type    = string
  default = "1"
}

variable "password_secret_accessors" {
  type    = set(string)
  default = []
}
