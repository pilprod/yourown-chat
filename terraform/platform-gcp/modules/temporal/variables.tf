variable "enabled" {
  type    = bool
  default = false
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
