output "email" {
  description = "Email of the created Google service account."
  value       = google_service_account.this.email
}

output "iam_member" {
  description = "IAM member string (serviceAccount:<email>) for granting further roles."
  value       = "serviceAccount:${google_service_account.this.email}"
}

output "ksa_annotation" {
  description = "Value for the iam.gke.io/gcp-service-account annotation on the KSA."
  value       = google_service_account.this.email
}
