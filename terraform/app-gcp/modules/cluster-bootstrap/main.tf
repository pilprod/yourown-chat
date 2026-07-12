# Cluster-scoped bootstrap releases the helm/ workloads depend on
# (docs/DEPLOY.md "One-time setup" step 2), installed by Terraform instead of
# a manual `helm upgrade --install` from an operator workstation.

# Mattermost Operator + CRDs. Prod Mattermost (helm/mattermost/) is an
# operator CR, so the operator must exist before Cloud Deploy ships it. No
# custom values: the operator's default scheduling lands on the untainted dev
# pool alongside kube-system, which is intentional -- the tainted prod pool is
# reserved for prod workloads that explicitly tolerate it.
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
