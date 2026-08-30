output "contract" {
  description = "Stable platform contract consumed by application delivery; no data-plane Gateway is created here."
  value = {
    enabled                    = var.enabled
    namespace                  = var.namespace
    gateway_api_version        = local.gateway_api_version
    gateway_class_name         = local.agentgateway_gateway_class
    controller_name            = local.agentgateway_controller
    chart_version              = local.agentgateway_chart_version
    service_account_name       = local.agentgateway_service_account
    read_cluster_role_name     = local.read_cluster_role_name
    deployer_cluster_role_name = local.deployer_cluster_role_name
    controller_release_name    = try(helm_release.controller[0].name, null)
    crd_release_name           = try(helm_release.crds[0].name, null)
    gateway_api_asset_sha256   = local.gateway_api_asset_sha256
  }
}
