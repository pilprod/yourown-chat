output "stateful_set_name" {
  value       = kubernetes_stateful_set_v1.this.metadata[0].name
  description = "Terraform-managed persistent development PostgreSQL StatefulSet."
}
