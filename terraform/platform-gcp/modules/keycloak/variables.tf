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
variable "cluster_dns_ip" {
  type        = string
  description = "Exact ClusterIP of the GKE kube-dns Service allowed by the Dataplane V2 egress policy."
  validation {
    condition     = can(cidrhost("${var.cluster_dns_ip}/32", 0))
    error_message = "cluster_dns_ip must be a valid IPv4 address."
  }
}
variable "database_password" {
  type      = string
  sensitive = true
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
  default = "https://auth.yourown.chat"
  validation {
    condition     = var.public_url == "https://auth.yourown.chat"
    error_message = "public_url must be the canonical https://auth.yourown.chat origin."
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
