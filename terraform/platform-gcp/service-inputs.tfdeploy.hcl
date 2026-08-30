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
      database_names = ["substrate"]
      # The first platform apply created this exact logical database but failed
      # before recording its resource address. Import only this database; the
      # sibling kagent database remains on the normal create path. Remove this
      # one-shot opt-in after a successful import; state keeps managed ownership.
      adopt_existing_database_names = ["substrate"]
      password_secret_id            = "substrate-db-password"
      connection_secret_id          = "substrate-database-url"
      password_rotation             = "1"
      kubernetes_connection_secret_accessors = [{
        namespace       = "ate-system"
        service_account = "ate-api-server"
      }]
    }
  }
}
