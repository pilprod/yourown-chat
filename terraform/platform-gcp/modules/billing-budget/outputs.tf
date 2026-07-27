output "name" {
  description = "Full Cloud Billing Budget resource name."
  value       = google_billing_budget.monthly.name
}

output "display_name" {
  description = "Human-readable monthly budget name."
  value       = google_billing_budget.monthly.display_name
}
