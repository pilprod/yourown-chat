variable "enabled" {
  type    = bool
  default = false
}
variable "cloudsql_private_ip" { type = string }
variable "database_password" {
  type      = string
  sensitive = true
}

variable "chart_version" {
  type    = string
  default = "1.2.0"
}

variable "namespace" {
  type    = string
  default = "temporal"
}

variable "labels" {
  type    = map(string)
  default = {}
}
