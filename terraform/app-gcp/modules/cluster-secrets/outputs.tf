output "namespace_names" {
  description = "Names of the namespaces created by this module."
  value       = [for ns in kubernetes_namespace.this : ns.metadata[0].name]
}

# NOTE: no secret_names output. The Secret names derive from the (sensitive)
# secrets input, so exporting them as a root-module output trips Terraform's
# "output refers to sensitive values" check, and the output has no consumer.
