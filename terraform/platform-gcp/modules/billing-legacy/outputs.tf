output "project_id" {
  description = "Former legacy billing project."
  value       = var.project_id
}

output "dataset_id" {
  description = "Former legacy billing dataset."
  value       = google_bigquery_dataset.this.dataset_id
}

output "detailed_export_table" {
  description = "Former managed detailed export table."
  value       = "${var.project_id}.${google_bigquery_dataset.this.dataset_id}.gcp_billing_export_resource_v1_${replace(var.billing_account_id, "-", "_")}"
}
