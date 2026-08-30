# Service-owned database requests consumed only by the existing platform-gcp Stack.
# Secret values remain in Secret Manager; this file contains identifiers and accessors.
locals {
  additional_database_users = {
    kagent = {
      database_names       = ["kagent"]
      password_secret_id   = "kagent-db-password"
      connection_secret_id = "kagent-database-url"
      password_rotation    = "1"
      kubernetes_connection_secret_accessors = [{
        namespace       = "kagent-system"
        service_account = "kagent-controller"
      }]
    }
    substrate = {
      database_names       = ["substrate"]
      password_secret_id   = "substrate-db-password"
      connection_secret_id = "substrate-database-url"
      password_rotation    = "1"
      kubernetes_connection_secret_accessors = [{
        namespace       = "ate-system"
        service_account = "ate-api-server"
      }]
    }
  }
}
