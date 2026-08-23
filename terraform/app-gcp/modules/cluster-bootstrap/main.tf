# Cluster-scoped bootstrap releases the helm/ workloads depend on
# (docs/DEPLOY.md "One-time setup" step 2), installed by Terraform instead of
# a manual `helm upgrade --install` from an operator workstation.

# Mattermost Operator + CRDs. Prod Mattermost (helm/mattermost/) is an
# operator CR, so the operator must exist before Cloud Deploy ships it. No
# custom values: the operator lands on the shared autoscaling pool alongside
# kube-system; system/operator pods have priority above disposable dev pods.
import {
  for_each = var.adopt_existing_releases ? toset(["mattermost-operator/mattermost-operator"]) : toset([])
  to       = helm_release.mattermost_operator
  id       = each.value
}

resource "helm_release" "mattermost_operator" {
  name       = "mattermost-operator"
  repository = "https://helm.mattermost.com"
  chart      = "mattermost-operator"
  version    = var.mattermost_operator_chart_version

  namespace        = "mattermost-operator"
  create_namespace = true

  wait    = true
  timeout = 600
}

# Public edge: ingress-nginx pinned to the reserved "white address" and
# admitting only Cloudflare source ranges. Skipped entirely when no reserved
# IP is supplied (environments without a public edge). Values are rendered
# from templates/ingress-nginx-values.yaml.tftpl -- keep it in sync with the
# manual-fallback copy helm/ingress-nginx/values.yaml.
import {
  for_each = var.adopt_existing_releases && var.ingress_load_balancer_ip != null ? toset(["ingress-nginx/ingress-nginx"]) : toset([])
  to       = helm_release.ingress_nginx[0]
  id       = each.value
}

resource "helm_release" "ingress_nginx" {
  count = var.ingress_load_balancer_ip != null ? 1 : 0

  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version

  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    templatefile("${path.module}/templates/ingress-nginx-values.yaml.tftpl", {
      load_balancer_ip = var.ingress_load_balancer_ip
    })
  ]

  # wait covers LB provisioning: the release is only healthy once the Service
  # holds the reserved IP and the controller pod passes its probes.
  wait    = true
  timeout = 600
}

# kagent M0 is an isolated, explicitly unqualified testbed. CRDs are installed
# first so the controller never races custom-resource discovery. release.lock
# and helm/test/kagent-release.test.sh verify the OCI archive checksums before
# this gate is enabled; the reviewed OCI digests are retained in release
# metadata so any pin change is visible in the Terraform plan.
resource "helm_release" "kagent_crds" {
  count = var.kagent_testbed_enabled ? 1 : 0

  name       = "kagent-crds"
  repository = var.kagent_chart_repository
  chart      = "kagent-crds"
  version    = var.kagent_chart_version
  description = join(" ", [
    "source=${var.kagent_source_commit}",
    "oci=${var.kagent_crds_chart_oci_digest}",
  ])

  namespace        = var.kagent_system_namespace
  create_namespace = false
  values           = [file("${path.module}/../../../../helm/kagent/crds-values.yaml")]

  wait    = true
  timeout = 600
}

resource "helm_release" "kagent" {
  count = var.kagent_testbed_enabled ? 1 : 0

  name       = "kagent"
  repository = var.kagent_chart_repository
  chart      = "kagent"
  version    = var.kagent_chart_version
  description = join(" ", [
    "source=${var.kagent_source_commit}",
    "oci=${var.kagent_chart_oci_digest}",
  ])

  namespace        = var.kagent_system_namespace
  create_namespace = false
  values           = [file("${path.module}/../../../../helm/kagent/values-testbed.yaml")]

  wait    = true
  timeout = 900

  depends_on = [helm_release.kagent_crds]
}
