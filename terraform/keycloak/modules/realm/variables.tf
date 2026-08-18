variable "realm_name" { type = string }
variable "public_host" { type = string }
variable "broker_redirect_uri" { type = string }
variable "terraform_service_account_user_id" { type = string }
variable "terraform_client_internal_id" { type = string }
variable "realm_management_client_id" { type = string }
variable "bootstrap_admin_client_secret" {
  type      = string
  ephemeral = true
  sensitive = true
}
variable "smtp_host" { type = string }
variable "smtp_from" { type = string }
