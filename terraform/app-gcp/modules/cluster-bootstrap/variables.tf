variable "mattermost_operator_chart_version" {
  type        = string
  description = "mattermost/mattermost-operator chart version to install."
}

variable "ingress_nginx_chart_version" {
  type        = string
  description = "ingress-nginx/ingress-nginx chart version to install."
}

variable "ingress_load_balancer_ip" {
  type        = string
  description = "Reserved regional external IP to pin the ingress-nginx Service to (the platform's published ingress_ip_address). null skips the ingress-nginx release."
  default     = null
}
