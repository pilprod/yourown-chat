variable "realm_name" { type = string }
variable "public_host" { type = string }
variable "broker_redirect_uri" { type = string }
variable "terraform_client_id" { type = string }

variable "terraform_client_secret" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "terraform_client_secret_version" { type = string }
variable "smtp_host" { type = string }
variable "smtp_from" { type = string }
