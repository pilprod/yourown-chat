variable "realm_name" { type = string }
variable "public_host" { type = string }
variable "broker_redirect_uris" { type = set(string) }
variable "terraform_service_account_user_id" { type = string }
variable "terraform_client_internal_id" { type = string }
variable "realm_management_client_id" { type = string }
variable "smtp_host" { type = string }
variable "smtp_from" { type = string }
