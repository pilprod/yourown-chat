output "dataset_id" {
  description = "BigQuery dataset ID selected for the Cloud Billing export."
  value       = google_bigquery_dataset.this.dataset_id
}

output "detailed_export_table" {
  description = "Expected detailed usage export table. Cloud Billing creates it after export is enabled."
  value       = "${var.project_id}.${google_bigquery_dataset.this.dataset_id}.gcp_billing_export_resource_v1_${replace(var.billing_account_id, "-", "_")}"
}
