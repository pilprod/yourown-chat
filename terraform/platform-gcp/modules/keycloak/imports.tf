# Recovery imports for the resources created by configuration 61 before its
# deployment was canceled. Remove this file after one successful apply records
# every object in the Keycloak component state.

import {
  to = google_secret_manager_secret.bootstrap_admin[0]
  id = "projects/${var.project_id}/secrets/keycloak-bootstrap-admin-client-secret"
}

import {
  to = kubernetes_namespace_v1.this[0]
  id = var.namespace
}

import {
  to = kubernetes_resource_quota_v1.this[0]
  id = "${var.namespace}/compute-budget"
}

import {
  to = kubernetes_limit_range_v1.this[0]
  id = "${var.namespace}/container-defaults"
}

import {
  to = kubernetes_service_account_v1.this[0]
  id = "${var.namespace}/keycloak"
}

import {
  to = kubernetes_secret_v1.runtime[0]
  id = "${var.namespace}/keycloak-runtime"
}

import {
  to = kubernetes_service_v1.cloudsql[0]
  id = "${var.namespace}/keycloak-cloudsql"
}

import {
  to = kubernetes_endpoints_v1.cloudsql[0]
  id = "${var.namespace}/keycloak-cloudsql"
}

import {
  to = kubernetes_service_v1.this[0]
  id = "${var.namespace}/keycloak"
}

import {
  to = kubernetes_network_policy_v1.isolation[0]
  id = "${var.namespace}/keycloak-isolation"
}

import {
  to = kubernetes_deployment_v1.this[0]
  id = "${var.namespace}/keycloak"
}
