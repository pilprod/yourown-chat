#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
chart="${repo_root}/helm/mattermost"
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

common_args=(
  --set mattermost_dev_image=example.invalid/mattermost@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --set mattermost_version=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --set mattermost_dev_gsa=dev@example.invalid
  --set mattermost_gsa=prod@example.invalid
  --set matterbridge_gsa=bridge@example.invalid
  --set mattermost_cloudsql_ip=10.0.0.2
  --set filestore_bucket=test
  --set aop_verify_client=off
)

helm template mattermost-dev "${chart}" \
  -f "${chart}/values.yaml" \
  -f "${chart}/values-dev.yaml" \
  "${common_args[@]}" > "${render_dir}/dev.yaml"

helm template mattermost-prod "${chart}" \
  -f "${chart}/values.yaml" \
  -f "${chart}/values-prod.yaml" \
  "${common_args[@]}" \
  --set mattermost_calls_ip=203.0.113.10 > "${render_dir}/prod.yaml"

grep -Fq 'name: MM_CALLS_RTCD_SERVICE_URL' "${render_dir}/dev.yaml"
grep -Fq 'name: MM_SERVICESETTINGS_ENABLEDEVELOPER' "${render_dir}/dev.yaml"
grep -Fq 'name: MM_SERVICESETTINGS_ENABLETESTING' "${render_dir}/dev.yaml"
[[ "$(grep -Fc 'name: MM_LOGSETTINGS_ENABLECONSOLE' "${render_dir}/dev.yaml")" == 1 ]]
[[ "$(grep -Fc 'name: MM_LOGSETTINGS_CONSOLELEVEL' "${render_dir}/dev.yaml")" == 1 ]]
[[ "$(grep -Fc 'name: MM_LOGSETTINGS_CONSOLEJSON' "${render_dir}/dev.yaml")" == 1 ]]
grep -Fq 'name: MM_PLUGINSETTINGS_PLUGINSTATES' "${render_dir}/dev.yaml"
grep -Fq 'com.mattermost.calls":{"Enable":true}' "${render_dir}/dev.yaml"
if grep -Fq 'MM_PLUGINSETTINGS_PLUGINSTATES_COM_MATTERMOST_CALLS' "${render_dir}/dev.yaml"; then
  echo "flattened PluginStates environment override is ignored by Mattermost" >&2
  exit 1
fi
grep -Fq 'value: "http://dev-rtcd.dev.svc.cluster.local:8045"' "${render_dir}/dev.yaml"
grep -Fq 'name: dev-rtcd' "${render_dir}/dev.yaml"

grep -Fq 'name: mattermost-rtcd-udp' "${render_dir}/prod.yaml"
grep -Fq 'name: mattermost-rtcd-tcp' "${render_dir}/prod.yaml"
grep -Fq 'name: MM_PLUGINSETTINGS_PLUGINSTATES' "${render_dir}/prod.yaml"
grep -Fq 'com.mattermost.calls":{"Enable":true}' "${render_dir}/prod.yaml"
grep -Fq 'name: MM_LOGSETTINGS_ENABLECONSOLE' "${render_dir}/prod.yaml"
grep -Fq 'name: MM_LOGSETTINGS_CONSOLELEVEL' "${render_dir}/prod.yaml"
grep -Fq 'name: MM_LOGSETTINGS_CONSOLEJSON' "${render_dir}/prod.yaml"
if grep -Fq 'MM_PLUGINSETTINGS_PLUGINSTATES_COM_MATTERMOST_CALLS' "${render_dir}/prod.yaml"; then
  echo "flattened PluginStates environment override is ignored by Mattermost" >&2
  exit 1
fi
grep -Fq 'storageClassName: rtcd-cmek' "${render_dir}/prod.yaml"
grep -Fq 'fsGroup: 65532' "${render_dir}/prod.yaml"
[[ "$(grep -Fc 'loadBalancerIP: "203.0.113.10"' "${render_dir}/prod.yaml")" == 2 ]]
grep -Fq 'value: "http://mattermost-rtcd.mattermost-rtcd.svc.cluster.local:8045"' "${render_dir}/prod.yaml"
grep -Fq 'name: RTCD_RTC_ICEHOSTOVERRIDE' "${render_dir}/prod.yaml"
grep -Fq 'name: allow-mattermost-api' "${render_dir}/prod.yaml"
grep -Fq 'name: allow-rtcd-api' "${render_dir}/prod.yaml"

extract_resource() {
  local kind="$1"
  local name="$2"
  local output="$3"
  awk -v kind="${kind}" -v name="${name}" '
    BEGIN { RS = "---" }
    $0 ~ "kind: " kind && $0 ~ "name: " name "([[:space:]]|$)" { print }
  ' "${render_dir}/prod.yaml" > "${output}"
  test -s "${output}"
}

# The direct Calls address is intentionally a media-only edge. The RTCD API
# must never become part of either public forwarding rule.
extract_resource Service mattermost-rtcd "${render_dir}/rtcd-api.yaml"
extract_resource Service mattermost-rtcd-udp "${render_dir}/rtcd-udp.yaml"
extract_resource Service mattermost-rtcd-tcp "${render_dir}/rtcd-tcp.yaml"

grep -Fq 'type: ClusterIP' "${render_dir}/rtcd-api.yaml"
grep -Fq 'port: 8045' "${render_dir}/rtcd-api.yaml"
! grep -Fq 'type: LoadBalancer' "${render_dir}/rtcd-api.yaml"

grep -Fq 'type: LoadBalancer' "${render_dir}/rtcd-udp.yaml"
grep -Fq 'port: 8443' "${render_dir}/rtcd-udp.yaml"
grep -Fq 'protocol: UDP' "${render_dir}/rtcd-udp.yaml"
! grep -Eq 'port: (443|8045|8065)$' "${render_dir}/rtcd-udp.yaml"

grep -Fq 'type: LoadBalancer' "${render_dir}/rtcd-tcp.yaml"
grep -Fq 'port: 8443' "${render_dir}/rtcd-tcp.yaml"
grep -Fq 'protocol: TCP' "${render_dir}/rtcd-tcp.yaml"
! grep -Eq 'port: (443|8045|8065)$' "${render_dir}/rtcd-tcp.yaml"

# A compromised media pod gets neither Kubernetes credentials nor a route to
# RFC1918/link-local destinations (Mattermost, MCP, Cloud SQL, metadata).
extract_resource Deployment mattermost-rtcd "${render_dir}/rtcd-deployment.yaml"
grep -Fq 'automountServiceAccountToken: false' "${render_dir}/rtcd-deployment.yaml"
grep -Fq 'readOnlyRootFilesystem: true' "${render_dir}/rtcd-deployment.yaml"
grep -Fq 'allowPrivilegeEscalation: false' "${render_dir}/rtcd-deployment.yaml"
grep -Fq 'drop: ["ALL"]' "${render_dir}/rtcd-deployment.yaml"

extract_resource NetworkPolicy allow-dns-and-public-media-egress \
  "${render_dir}/rtcd-egress.yaml"
for blocked_cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
  grep -Fq -- "- ${blocked_cidr}" "${render_dir}/rtcd-egress.yaml"
done

extract_resource NetworkPolicy allow-public-media "${render_dir}/rtcd-public.yaml"
grep -Fq 'cidr: 0.0.0.0/0' "${render_dir}/rtcd-public.yaml"
grep -Fq 'protocol: UDP, port: 8443' "${render_dir}/rtcd-public.yaml"
grep -Fq 'protocol: TCP, port: 8443' "${render_dir}/rtcd-public.yaml"
! grep -Eq 'port: (443|8045|8065)' "${render_dir}/rtcd-public.yaml"

extract_resource NetworkPolicy allow-mattermost-api "${render_dir}/rtcd-api-ingress.yaml"
grep -Fq 'kubernetes.io/metadata.name: mattermost' "${render_dir}/rtcd-api-ingress.yaml"
grep -Fq 'protocol: TCP, port: 8045' "${render_dir}/rtcd-api-ingress.yaml"

extract_resource NetworkPolicy allow-rtcd-api "${render_dir}/mattermost-rtcd-egress.yaml"
grep -Fq 'kubernetes.io/metadata.name: mattermost-rtcd' \
  "${render_dir}/mattermost-rtcd-egress.yaml"
grep -Fq 'protocol: TCP, port: 8045' "${render_dir}/mattermost-rtcd-egress.yaml"

# The prod verifier gets only the same-namespace 8065 path it needs. It does
# not weaken the default deny or grant Mattermost access to MCP namespaces.
extract_resource NetworkPolicy allow-calls-smoke-ingress \
  "${render_dir}/calls-smoke-ingress.yaml"
extract_resource NetworkPolicy allow-calls-smoke-egress \
  "${render_dir}/calls-smoke-egress.yaml"
grep -Fq 'app: mattermost-calls-smoke' "${render_dir}/calls-smoke-ingress.yaml"
grep -Fq 'protocol: TCP, port: 8065' "${render_dir}/calls-smoke-ingress.yaml"
grep -Fq 'app: mattermost-calls-smoke' "${render_dir}/calls-smoke-egress.yaml"
grep -Fq 'protocol: TCP, port: 8065' "${render_dir}/calls-smoke-egress.yaml"
! grep -Eq 'port: (443|8045|8443)' "${render_dir}/calls-smoke-ingress.yaml"
! grep -Eq 'port: (443|8045|8443)' "${render_dir}/calls-smoke-egress.yaml"

grep -Fq 'app: mattermost-calls-smoke' \
  "${repo_root}/helm/mattermost/verify/prod-job.yaml"

grep -Fq 'http://dev-rtcd.dev.svc.cluster.local:8045/version' \
  "${repo_root}/helm/skaffold-mattermost.yaml"
grep -Fq 'http://mattermost-rtcd.mattermost-rtcd.svc.cluster.local:8045/version' \
  "${repo_root}/helm/skaffold-mattermost.yaml"
grep -Fq 'http://mattermost.mattermost.svc.cluster.local:8065/plugins/com.mattermost.calls/version' \
  "${repo_root}/helm/skaffold-mattermost.yaml"
grep -Fq 'https://yourown.chat/plugins/com.mattermost.calls/version' \
  "${repo_root}/helm/skaffold-mattermost.yaml"
[[ "$(grep -Fc -- '--retry 12 --retry-all-errors --retry-delay 5' \
  "${repo_root}/helm/skaffold-mattermost.yaml")" -eq 2 ]]
[[ "$(grep -Fc -- '--connect-timeout 3 --max-time 10' \
  "${repo_root}/helm/skaffold-mattermost.yaml")" == 2 ]]
grep -Fq 'dev-mattermost dev-rtcd' "${repo_root}/helm/skaffold-mattermost.yaml"

printf 'Mattermost Calls rendering tests passed\n'
