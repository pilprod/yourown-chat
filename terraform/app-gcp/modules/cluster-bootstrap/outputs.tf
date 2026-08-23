output "mattermost_operator_chart_version" {
  description = "Installed mattermost-operator chart version."
  value       = helm_release.mattermost_operator.version
}

output "ingress_nginx_chart_version" {
  description = "Installed ingress-nginx chart version (null when the release is skipped)."
  value       = one(helm_release.ingress_nginx[*].version)
}

output "kagent_chart_version" {
  description = "Installed kagent chart version (null while the testbed gate is disabled)."
  value       = one(helm_release.kagent[*].version)
}
