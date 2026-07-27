output "project_id" {
  description = "Dedicated FinOps project linked to the legacy billing account."
  value       = var.project_id
}

output "dataset_id" {
  description = "Dataset selected for the legacy Detailed usage cost export."
  value       = google_bigquery_dataset.this.dataset_id
}

output "detailed_export_table" {
  description = "Expected table created by Cloud Billing after the legacy export is enabled."
  value       = "${var.project_id}.${google_bigquery_dataset.this.dataset_id}.gcp_billing_export_resource_v1_${replace(var.billing_account_id, "-", "_")}"
}
