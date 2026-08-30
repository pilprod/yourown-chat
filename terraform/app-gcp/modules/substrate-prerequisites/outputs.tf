output "bootstrap_ready" {
  description = "True when the pre-sync namespace, exact contract and immutable Substrate CRDs are present."
  value = (
    var.bootstrap_enabled &&
    local.secret_contract_valid &&
    try(helm_release.substrate_crds[0].status == "deployed", false)
  )
}

output "release_ready" {
  description = "True only when bootstrap is ready and native Secret synchronization has been explicitly attested."
  value = (
    var.release_enabled &&
    var.native_secret_sync_ready &&
    var.bootstrap_enabled &&
    local.secret_contract_valid &&
    try(helm_release.substrate_crds[0].status == "deployed", false)
  )
}

output "substrate_crd_release" {
  description = "Terraform-owned immutable Substrate CRD release evidence."
  value = {
    name    = try(helm_release.substrate_crds[0].name, null)
    chart   = var.bootstrap_enabled ? var.substrate_crd_chart.ref : null
    version = var.bootstrap_enabled ? var.substrate_crd_chart.version : null
    status  = try(helm_release.substrate_crds[0].status, null)
  }
}

output "issuer" {
  description = "Cluster-specific issuer retained while discovery and JWKS use paired in-cluster API overrides."
  value       = "https://container.googleapis.com/v1/${var.gke_cluster_id}"
}

output "secret_contract" {
  description = "Non-sensitive Secret Manager IDs and exact native Kubernetes names/namespaces/keys, including Kubernetes-only derived values."
  value = {
    sources = var.secret_contract
    derived = var.derived_secret_contract
  }
}

output "enrollment_admin_service_account" {
  description = "Exact KSA subject allowed to create external-provider enrollments."
  value       = "system:serviceaccount:${local.substrate_namespace}:ate-enrollment-admin"
}
