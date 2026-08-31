output "bootstrap_ready" {
  description = "True when the pre-sync namespace, exact contract and immutable Substrate CRDs are present."
  value = (
    var.bootstrap_enabled &&
    local.secret_contract_valid &&
    try(helm_release.substrate_crds[0].status == "deployed", false)
  )
}

output "release_ready" {
  description = "True only when native Secrets are attested and the Terraform-owned Substrate application, API/controller, AgentgatewayParameters, Gateway and TLSRoute exist. Gateway Programmed state remains a rollout verification gate."
  value = (
    var.release_enabled &&
    var.native_secret_sync_ready &&
    var.bootstrap_enabled &&
    local.secret_contract_valid &&
    try(helm_release.substrate_crds[0].status == "deployed", false) &&
    try(helm_release.substrate_application[0].status == "deployed", false) &&
    try(data.kubernetes_resource.agentgateway_parameters[0].object.metadata.name == "substrate-broker", false) &&
    try(data.kubernetes_resource.substrate_api[0].object.metadata.name == "ate-api-server", false) &&
    try(tonumber(data.kubernetes_resource.substrate_api[0].object.status.availableReplicas) >= 1, false) &&
    try(data.kubernetes_resource.substrate_controller[0].object.metadata.name == "ate-controller", false) &&
    try(tonumber(data.kubernetes_resource.substrate_controller[0].object.status.availableReplicas) >= 1, false) &&
    try(data.kubernetes_resource.external_provider_gateway[0].object.metadata.name == "external-provider-broker", false) &&
    try(data.kubernetes_resource.external_provider_tls_route[0].object.metadata.name == "external-provider-broker", false)
  )
}

output "external_broker_smoke_ready" {
  description = "Live Terraform-managed attestation read by the production PREDEPLOY gate; it intentionally does not participate in dev release readiness."
  value = (
    var.bootstrap_enabled &&
    try(
      kubernetes_config_map_v1.production_promotion_gate[0].data["external_broker_smoke_ready"] == "true" &&
      kubernetes_config_map_v1.production_promotion_gate[0].data["cloud_deploy_release"] != "",
      false,
    )
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

output "substrate_application_release" {
  description = "Terraform-owned immutable shared Substrate application release evidence."
  value = {
    name    = try(helm_release.substrate_application[0].name, null)
    chart   = var.release_enabled ? var.substrate_application_chart.ref : null
    version = var.release_enabled ? var.substrate_application_chart.version : null
    status  = try(helm_release.substrate_application[0].status, null)
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
