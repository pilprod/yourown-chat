output "release" {
  description = "Generic release and readiness status for the catalog bundle."
  value = {
    bundle_key               = var.bundle_key
    provisioned              = local.provisioned
    application_requested    = var.bundle.application_enabled
    database_bindings_ready  = local.database_bindings_ready
    application_materialized = local.application_ready
    candidate_tag            = var.bundle.candidate_tag
    product_commit           = var.bundle.product_commit
    source_commit            = var.bundle.source_commit
    namespace                = local.control_namespace
    crd_release_name         = local.provisioned ? helm_release.crds[0].name : null
    crd_status               = try(helm_release.crds[0].status, null)
    application_release_name = local.application_ready ? helm_release.application[0].name : null
    application_status       = try(helm_release.application[0].status, null)
  }
}
