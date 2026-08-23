#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_file="${repo_root}/helm/kagent/release.lock"

# release.lock contains only reviewed literal assignments.
# shellcheck disable=SC1090
source "${lock_file}"

fail() {
  printf 'kagent release test: %s\n' "$*" >&2
  exit 1
}

[[ "${KAGENT_RELEASE_CHANNEL}" == "testbed" ]] || fail "unexpected release channel"
[[ "${KAGENT_QUALIFICATION_STATUS}" == "bootstrap-unqualified" ]] || fail "testbed must remain unqualified"
[[ "${KAGENT_FORK_REPOSITORY}" == "https://github.com/pilprod/kagent.git" ]] || fail "fork repository drift"
[[ "${KAGENT_SOURCE_TAG}" == "v${KAGENT_VERSION}" ]] || fail "tag/version mismatch"
[[ "${KAGENT_SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source commit"
[[ "${KAGENT_PREVIEW_SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "invalid preview commit"
[[ "${KAGENT_PATCHSET_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid patch-set digest"
for digest in \
  "${KAGENT_CHART_OCI_DIGEST}" \
  "${KAGENT_CRDS_CHART_OCI_DIGEST}"; do
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid OCI digest ${digest}"
done
for digest in \
  "${KAGENT_CHART_ARCHIVE_SHA256}" \
  "${KAGENT_CRDS_CHART_ARCHIVE_SHA256}"; do
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid archive digest ${digest}"
done

bootstrap="${repo_root}/terraform/app-gcp/modules/cluster-bootstrap/main.tf"
deployment="${repo_root}/terraform/app-gcp/app.tfdeploy.hcl"
network_policy="${repo_root}/terraform/app-gcp/modules/workload-scheduling/main.tf"
values="${repo_root}/helm/kagent/values-testbed.yaml"

grep -Fq 'resource "helm_release" "kagent_crds"' "${bootstrap}"
grep -Fq 'resource "helm_release" "kagent"' "${bootstrap}"
grep -Fq 'depends_on = [helm_release.kagent_crds]' "${bootstrap}"
grep -Eq 'kagent_testbed_enabled[[:space:]]*=[[:space:]]*false' "${deployment}"
grep -Eq "kagent_chart_version[[:space:]]*=[[:space:]]*\"${KAGENT_VERSION}\"" "${deployment}"
grep -Eq "kagent_source_commit[[:space:]]*=[[:space:]]*\"${KAGENT_SOURCE_COMMIT}\"" "${deployment}"
grep -Eq "kagent_chart_oci_digest[[:space:]]*=[[:space:]]*\"${KAGENT_CHART_OCI_DIGEST}\"" "${deployment}"
grep -Eq "kagent_crds_chart_oci_digest[[:space:]]*=[[:space:]]*\"${KAGENT_CRDS_CHART_OCI_DIGEST}\"" "${deployment}"
grep -Fq '"kubernetes.io/metadata.name" = "yourown-agents"' "${network_policy}"
grep -Fq 'gateway remains the single durable' "${network_policy}"

grep -Fq 'mode: unsecure' "${values}"
grep -Fq 'replicas: 0' "${values}"
grep -Fq 'default: ollama' "${values}"
! grep -Eq 'apiKey:[[:space:]]*[^[:space:]#]' "${values}" || fail "inline model API key"

chart_cache="${KAGENT_CHART_CACHE:-}"
cleanup_dir=""
if [[ -z "${chart_cache}" && "${KAGENT_VERIFY_REMOTE:-0}" == "1" ]]; then
  command -v helm >/dev/null || fail "helm is required for remote verification"
  cleanup_dir="$(mktemp -d)"
  chart_cache="${cleanup_dir}"
  trap 'rm -rf "${cleanup_dir}"' EXIT
  helm pull "${KAGENT_CHART_REPOSITORY}/kagent" \
    --version "${KAGENT_VERSION}" --destination "${chart_cache}"
  helm pull "${KAGENT_CHART_REPOSITORY}/kagent-crds" \
    --version "${KAGENT_VERSION}" --destination "${chart_cache}"
fi

if [[ -n "${chart_cache}" ]]; then
  command -v helm >/dev/null || fail "helm is required for chart rendering"
  app_chart="${chart_cache}/kagent-${KAGENT_VERSION}.tgz"
  crds_chart="${chart_cache}/kagent-crds-${KAGENT_VERSION}.tgz"
  [[ -f "${app_chart}" ]] || fail "missing ${app_chart}"
  [[ -f "${crds_chart}" ]] || fail "missing ${crds_chart}"

  actual_app_sha="$(shasum -a 256 "${app_chart}" | awk '{print $1}')"
  actual_crds_sha="$(shasum -a 256 "${crds_chart}" | awk '{print $1}')"
  [[ "${actual_app_sha}" == "${KAGENT_CHART_ARCHIVE_SHA256}" ]] || fail "application chart checksum mismatch"
  [[ "${actual_crds_sha}" == "${KAGENT_CRDS_CHART_ARCHIVE_SHA256}" ]] || fail "CRD chart checksum mismatch"

  rendered="$(mktemp)"
  trap 'rm -f "${rendered}"; [[ -z "${cleanup_dir}" ]] || rm -rf "${cleanup_dir}"' EXIT
  helm template kagent "${app_chart}" \
    --namespace kagent-system \
    --values "${values}" > "${rendered}"
  helm template kagent-crds "${crds_chart}" \
    --namespace kagent-system \
    --values "${repo_root}/helm/kagent/crds-values.yaml" >/dev/null

  grep -Fq 'name: kagent-controller' "${rendered}"
  grep -Fq 'WATCH_NAMESPACES: "kagent-system,kagent-testbed"' "${rendered}"
  grep -Fq 'image: "cr.kagent.dev/kagent-dev/kagent/controller:0.9.12"' "${rendered}"
  grep -Fq 'value: "unsecure"' "${rendered}"
  grep -Fq 'replicas: 0' "${rendered}"
  ! grep -Eq 'type: (LoadBalancer|NodePort)' "${rendered}" || fail "public Service rendered"
  ! grep -Fq 'name: kagent-tools' "${rendered}" || fail "built-in tools rendered"
  ! grep -Fq 'name: querydoc' "${rendered}" || fail "querydoc rendered"
fi

printf 'kagent release lock and testbed profile passed\n'
