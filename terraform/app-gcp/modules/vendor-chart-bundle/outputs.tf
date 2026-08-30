output "release" {
  description = "Generic release and readiness status for the service-owned bundle."
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
    application_release_name = local.application_ready ? helm_release.application_handoff_source[0].name : null
    application_status       = try(helm_release.application_handoff_source[0].status, null)
  }

  # Validate immutable repository inputs even while a bundle is disabled or
  # waiting for its database binding. Resource-level preconditions below remain
  # as a final guard immediately before either Helm release is materialized.
  precondition {
    condition = alltrue([
      for chart in [var.bundle.charts.crds, var.bundle.charts.application] :
      startswith(chart.values_path, "helm/vendor/${var.bundle_key}/")
    ])
    error_message = "Each tracked values file must be owned by the directory matching bundle_key."
  }

  precondition {
    condition     = fileexists(local.crd_values_path) && sha256(local.crd_values) == var.bundle.charts.crds.values_sha256
    error_message = "The tracked CRD values file is missing or does not match the declared bundle checksum."
  }

  precondition {
    condition     = try(length(keys(yamldecode(local.crd_values))) >= 0, false)
    error_message = "The tracked CRD values file must contain a YAML object."
  }

  precondition {
    condition     = fileexists(local.application_values_path) && sha256(local.application_values) == var.bundle.charts.application.values_sha256
    error_message = "The tracked application values file is missing or does not match the declared bundle checksum."
  }

  precondition {
    condition     = try(length(keys(yamldecode(local.application_values))) >= 0, false)
    error_message = "The tracked application values file must contain a YAML object."
  }

  precondition {
    condition = alltrue([
      for digest in values(var.bundle.image_digests) :
      strcontains(local.application_values, digest)
    ])
    error_message = "Every declared image digest must be present in the tracked application values file."
  }
}
