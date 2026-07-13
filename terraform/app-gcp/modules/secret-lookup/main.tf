# Reads the LATEST enabled version of existing Secret Manager secrets so their
# plaintext can be rendered elsewhere (a Cloud Deploy deploy parameter that
# injects the value into a Kubernetes Secret). Read-only: owns no resources.
#
# Used for prod credentials the PLATFORM stack writes at init (the Cloud SQL
# connection string, the GCS HMAC keys). Those are sensitive, so the platform
# cannot publish them as linked-stack outputs; this stack reads them straight
# from Secret Manager instead (the shared apply SA holds secretmanager access).
data "google_secret_manager_secret_version" "this" {
  for_each = var.secret_ids

  project = var.project_id
  secret  = each.value
}
