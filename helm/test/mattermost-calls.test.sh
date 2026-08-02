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
grep -Fq 'name: MM_PLUGINSETTINGS_PLUGINSTATES_COM_MATTERMOST_CALLS' "${render_dir}/dev.yaml"
grep -Fq 'value: "http://dev-rtcd.dev.svc.cluster.local:8045"' "${render_dir}/dev.yaml"
grep -Fq 'name: dev-rtcd' "${render_dir}/dev.yaml"

grep -Fq 'name: mattermost-rtcd-udp' "${render_dir}/prod.yaml"
grep -Fq 'name: mattermost-rtcd-tcp' "${render_dir}/prod.yaml"
grep -Fq 'name: MM_PLUGINSETTINGS_PLUGINSTATES_COM_MATTERMOST_CALLS' "${render_dir}/prod.yaml"
grep -Fq 'storageClassName: rtcd-cmek' "${render_dir}/prod.yaml"
grep -Fq 'fsGroup: 65532' "${render_dir}/prod.yaml"
[[ "$(grep -Fc 'loadBalancerIP: "203.0.113.10"' "${render_dir}/prod.yaml")" == 2 ]]
grep -Fq 'value: "http://mattermost-rtcd.mattermost-rtcd.svc.cluster.local:8045"' "${render_dir}/prod.yaml"
grep -Fq 'name: RTCD_RTC_ICEHOSTOVERRIDE' "${render_dir}/prod.yaml"
grep -Fq 'name: allow-mattermost-api' "${render_dir}/prod.yaml"
grep -Fq 'name: allow-rtcd-api' "${render_dir}/prod.yaml"

grep -Fq 'http://dev-rtcd.dev.svc.cluster.local:8045/version' \
  "${repo_root}/helm/skaffold-mattermost.yaml"
grep -Fq 'http://mattermost-rtcd.mattermost-rtcd.svc.cluster.local:8045/version' \
  "${repo_root}/helm/skaffold-mattermost.yaml"
grep -Fq 'dev-mattermost dev-rtcd' "${repo_root}/helm/skaffold-mattermost.yaml"

printf 'Mattermost Calls rendering tests passed\n'
