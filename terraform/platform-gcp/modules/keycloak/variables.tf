variable "enabled" {
  type    = bool
  default = true
}

variable "project_id" { type = string }
variable "region" { type = string }
variable "encryption_key_name" {
  type    = string
  default = null
}
variable "cloudsql_private_ip" { type = string }
variable "database_password" {
  type      = string
  sensitive = true
}
variable "bootstrap_admin_client_secret" {
  type        = string
  ephemeral   = true
  sensitive   = true
  nullable    = true
  default     = null
  description = "Temporary master-realm bootstrap service credential supplied from the private HCP variable set."
}
variable "bootstrap_secret_version" {
  type        = string
  description = "Explicit numeric rotation marker for write-only bootstrap secret fields."
}
variable "image_version" {
  type    = string
  default = "26.7.1"
}
variable "public_url" {
  type    = string
  default = "https://yourown.chat/auth"
  validation {
    condition     = can(regex("^https://[^/]+/auth$", var.public_url))
    error_message = "public_url must be an HTTPS origin ending in /auth."
  }
}
variable "namespace" {
  type    = string
  default = "keycloak"
}
variable "labels" {
  type    = map(string)
  default = {}
}
