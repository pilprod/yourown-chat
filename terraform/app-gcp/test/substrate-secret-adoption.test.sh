#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Reuse the existing synthetic PKI, pool, PostgreSQL, gcloud and kubectl
# fixtures. The sourced test leaves its owner-only work directory alive until
# this process exits, so no real API is contacted here.
# shellcheck source=substrate-secret-bootstrap.test.sh
source "${script_dir}/substrate-secret-bootstrap.test.sh"

adopter="${app_dir}/scripts/adopt-kagent-substrate-secrets.go"
release_doc="${repo_dir}/docs/KAGENT_SUBSTRATE_RELEASE.md"
scripts_readme="${app_dir}/scripts/README.md"
runtime_tmp="${work}/adopt-runtime-tmp"
mkdir -p "${runtime_tmp}"

contract_records() {
  sed -n '/^source_contract_records()/,/^}/p' "${bootstrap}" |
    sed -n '/^postgres|/,/^CONTRACT$/p' |
    sed '$d'
}

reset_operator_secret_manager_versions() {
  local logical=""
  local secret_id=""
  local source=""
  while IFS='|' read -r logical secret_id _ _ source _; do
    [[ "${source}" == "operator-envelope-v1" ]] || continue
    rm -f -- "${work}/secret-store/${secret_id}" "${work}/secret-store/${secret_id}.version-"*
  done < <(contract_records)
  : > "${work}/secret-store/versions-add.log"
}

reset_drift_state() {
  rm -f -- \
    "${work}/secret-store/versions-list-count" \
    "${work}/secret-store/"*.extra-version \
    "${work}/secret-store/"*.disabled-version \
    "${work}/kube-store/secret-get-count" \
    "${work}/kube-store/postgres-drift-triggered"
}

assert_last_applied_count() {
  local expected="$1"
  local actual=""
  actual="$({
    for secret in "${work}/kube-store/"*.json; do
      jq -r '(.metadata.annotations // {}) | has("kubectl.kubernetes.io/last-applied-configuration") | select(.)' "${secret}"
    done
  } | wc -l | tr -d ' ')"
  [[ "${actual}" == "${expected}" ]] || fail "expected ${expected} last-applied annotations, found ${actual}"
}

snapshot_secret_data() {
  local destination="$1"
  : > "${destination}"
  for secret in "${work}/kube-store/"*.json; do
    printf '%s ' "$(basename "${secret}")" >> "${destination}"
    jq -cS '.data' "${secret}" | shasum -a 256 | awk '{print $1}' >> "${destination}"
  done
}

[[ -f "${adopter}" ]] || fail "memory-only adoption helper is missing"
gofmt_output="$(gofmt -d "${adopter}")"
[[ -z "${gofmt_output}" ]] || fail "memory-only adoption helper is not gofmt-clean"
go test "${adopter}" >/dev/null

if rg -n -- 'os\.(Create|CreateTemp|MkdirTemp|OpenFile|WriteFile)|ioutil\.(TempFile|WriteFile)|tempfile|--out-file' "${adopter}"; then
  fail "memory-only adoption helper contains a secret-bearing file path"
fi
rg -Fq -- '"--data-file=-"' "${adopter}" || fail "adoption upload is not stdin-only"
rg -Fq -- '"-f", "-"' "${adopter}" || fail "Kubernetes reconciliation is not stdin-only"
rg -Fq -- 'kubectl.kubernetes.io~1last-applied-configuration' "${adopter}" || fail "last-applied cleanup is missing"
rg -Fq -- 'CLOUDSDK_CORE_LOG_HTTP=false' "${adopter}" || fail "gcloud HTTP payload logging is not forced off"
rg -Fq -- 'ulimit -c 0' "${bootstrap}" || fail "memory-only adoption does not disable core dumps"
rg -Fq -- 'bootstrap-kagent-substrate-secrets.sh adopt-existing' "${release_doc}" || fail "release guide omits the one-time adoption command"
rg -Fq -- 'exclusive, quiesced adoption window' "${release_doc}" || fail "release guide omits the exclusive adoption window"
rg -Fq -- 'empty-or-one-exact retry semantics' "${scripts_readme}" || fail "script README omits adoption retry semantics"

reset_operator_secret_manager_versions
reset_drift_state
assert_last_applied_count 10
snapshot_secret_data "${work}/before-adoption.sha256"

expect_fail "adopt-existing bundle input" \
  "${bootstrap}" adopt-existing \
  --project test-project \
  --context test-context \
  --bundle "${work}/bundle.json"
grep -Fq 'does not accept --bundle' "${work}/expected.stderr" || fail "adopt-existing bundle rejection diagnostic is missing"

expect_fail "adopt-existing patch permission" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  MOCK_DENY_PATCH=1 \
  "${bootstrap}" adopt-existing --project test-project --context test-context
grep -Fq 'cannot patch Secrets' "${work}/expected.stderr" || fail "adopt-existing patch permission diagnostic is missing"
[[ ! -s "${work}/secret-store/versions-add.log" ]] || fail "adoption wrote Secret Manager versions before Kubernetes RBAC preflight"
assert_last_applied_count 10

cp "${work}/secret-store/substrate-database-url" "${work}/postgres.original"
printf '%s' 'postgresql://substrate:different-private-test-value@10.0.0.2:5432/substrate?sslmode=require' > "${work}/secret-store/substrate-database-url"
expect_fail "adopt-existing PostgreSQL mismatch" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  "${bootstrap}" adopt-existing --project test-project --context test-context
grep -Fq 'PostgreSQL value differs' "${work}/expected.stderr" || fail "PostgreSQL source-of-truth mismatch diagnostic is missing"
[[ ! -s "${work}/secret-store/versions-add.log" ]] || fail "PostgreSQL mismatch did not fail before Secret Manager writes"
assert_last_applied_count 10
cp "${work}/postgres.original" "${work}/secret-store/substrate-database-url"

cp "${work}/kube-store/kagent-dev__kagent-dev-ate-client-tls.json" "${work}/kagent-dev.original.json"
wrong_bundle="$(jq -er '.data["client-credential-bundle.pem"]' "${work}/kube-store/kagent-system__kagent-ate-client-tls.json")"
jq --arg wrong_bundle "${wrong_bundle}" \
  '.data["client-credential-bundle.pem"] = $wrong_bundle' \
  "${work}/kagent-dev.original.json" > "${work}/kube-store/kagent-dev__kagent-dev-ate-client-tls.json"
expect_fail "adopt-existing wrong dev SAN" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  "${bootstrap}" adopt-existing --project test-project --context test-context
grep -Fq 'required URI SAN' "${work}/expected.stderr" || fail "adoption did not validate the dev kagent URI SAN"
[[ ! -s "${work}/secret-store/versions-add.log" ]] || fail "invalid SAN did not fail before Secret Manager writes"
assert_last_applied_count 10
cp "${work}/kagent-dev.original.json" "${work}/kube-store/kagent-dev__kagent-dev-ate-client-tls.json"

# A pre-existing version is reusable only when its decoded contract matches the
# validated live source exactly. A semantically different but well-formed
# envelope must fail before any still-empty target is populated.
jq -c '
  {schema:"yourown.chat/native-secret-envelope/v1",data:.secrets.api_tls.data} |
  .data["client-ca.pem"] = "d3Jvbmc="
' "${work}/bundle.json" > "${work}/secret-store/substrate-ate-api-tls"
expect_fail "adopt-existing mismatched retry envelope" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  "${bootstrap}" adopt-existing --project test-project --context test-context
grep -Fq 'differs from the Kubernetes source' "${work}/expected.stderr" || fail "mismatched retry envelope diagnostic is missing"
[[ ! -s "${work}/secret-store/versions-add.log" ]] || fail "mismatched retry envelope did not fail before Secret Manager writes"
assert_last_applied_count 10
rm -f -- "${work}/secret-store/substrate-ate-api-tls"

# Drift the API Secret's resourceVersion and exact data on its second read,
# which occurs in the whole-set barrier immediately before the first possible
# Secret Manager upload. Nothing may be uploaded and all recovery annotations
# must remain.
cp "${work}/kube-store/ate-system__substrate-ate-api-tls.json" "${work}/api-pre-upload.original.json"
printf '0\n' > "${work}/kube-store/secret-get-count"
expect_fail "adopt-existing Kubernetes pre-upload drift" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  MOCK_KUBE_DRIFT_AT_GET_COUNT=12 \
  MOCK_KUBE_DRIFT_SECRET="ate-system/substrate-ate-api-tls" \
  "${bootstrap}" adopt-existing --project test-project --context test-context
grep -Fq 'changed during pre-upload validation' "${work}/expected.stderr" || fail "pre-upload Kubernetes drift diagnostic is missing"
[[ ! -s "${work}/secret-store/versions-add.log" ]] || fail "Kubernetes pre-upload drift did not fail before Secret Manager writes"
assert_last_applied_count 10
cp "${work}/api-pre-upload.original.json" "${work}/kube-store/ate-system__substrate-ate-api-tls.json"
reset_drift_state

# Fail the third upload. The first two exact envelopes remain as retry evidence;
# no Kubernetes mutation or annotation cleanup is permitted after this failure.
expect_fail "adopt-existing interrupted upload" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  MOCK_FAIL_ADD_SECRET="substrate-atenet-egress-server-tls" \
  "${bootstrap}" adopt-existing --project test-project --context test-context
[[ "$(wc -l < "${work}/secret-store/versions-add.log" | tr -d ' ')" == 2 ]] || fail "interrupted adoption did not stop at the expected upload"
assert_last_applied_count 10

# Complete the six missing uploads, then fail during Kubernetes reconciliation.
# Even when some exact data/labels were already applied, annotation cleanup must
# not begin until the entire ten-Secret set has reconciled and verified.
expect_fail "adopt-existing interrupted reconciliation" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  MOCK_FAIL_APPLY_SECRET="actor-id-jwt-pool" \
  "${bootstrap}" adopt-existing --project test-project --context test-context
[[ "$(wc -l < "${work}/secret-store/versions-add.log" | tr -d ' ')" == 8 ]] || fail "reconciliation failure did not leave the exact eight uploaded envelopes"
assert_last_applied_count 10

# Add a PostgreSQL Secret Manager version while Kubernetes reconciliation is in
# progress. The post-readback metadata barrier must fail before any last-applied
# annotation is removed.
reset_drift_state
expect_fail "adopt-existing PostgreSQL version-add reconciliation drift" \
  env PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  MOCK_SM_POSTGRES_VERSION_ADD_ON_APPLY_SECRET="actor-id-jwt-pool" \
  "${bootstrap}" adopt-existing --project test-project --context test-context
grep -Fq 'container substrate-database-url changed during adoption' "${work}/expected.stderr" || fail "PostgreSQL version-add drift diagnostic is missing"
assert_last_applied_count 10
reset_drift_state

# The first envelope list in the post-reconciliation cleanup barrier is call
# 20: nine initial classifications, nine pre-reconciliation validations,
# PostgreSQL at call 19, then api_tls. Both a concurrent version addition and a
# disable must fail before annotation cleanup begins.
for drift_mode in add disable; do
  printf '0\n' > "${work}/secret-store/versions-list-count"
  expect_fail "adopt-existing envelope ${drift_mode} cleanup drift" \
    env PATH="${work}/mock-bin:${PATH}" \
    TMPDIR="${runtime_tmp}" \
    MOCK_SECRET_STORE="${work}/secret-store" \
    MOCK_KUBE_STORE="${work}/kube-store" \
    MOCK_SM_VERSION_DRIFT_AT_LIST_COUNT=20 \
    MOCK_SM_VERSION_DRIFT_SECRET="substrate-ate-api-tls" \
    MOCK_SM_VERSION_DRIFT_MODE="${drift_mode}" \
    "${bootstrap}" adopt-existing --project test-project --context test-context
  grep -Fq 'changed during adoption' "${work}/expected.stderr" || fail "envelope ${drift_mode} drift diagnostic is missing"
  assert_last_applied_count 10
  reset_drift_state
done

printf '0\n' > "${work}/secret-store/versions-list-count"

adoption_output="$(
  PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  "${bootstrap}" adopt-existing --project test-project --context test-context 2>&1
)"

[[ "$(wc -l < "${work}/secret-store/versions-add.log" | tr -d ' ')" == 8 ]] || fail "retry did not reuse the exact uploaded envelopes"
[[ "$(find "${work}/kube-store" -type f -name '*.json' | wc -l | tr -d ' ')" == 10 ]] || fail "adoption changed the fixed Kubernetes Secret set"
assert_last_applied_count 0
[[ "$(cat "${work}/secret-store/versions-list-count")" == 36 ]] || fail "successful adoption did not execute all four nine-source Secret Manager barriers"
snapshot_secret_data "${work}/after-adoption.sha256"
cmp -s "${work}/before-adoption.sha256" "${work}/after-adoption.sha256" || fail "adoption changed native Kubernetes Secret bytes"

[[ "${adoption_output}" != *'private-test-value'* ]] || fail "adoption output leaked the PostgreSQL credential"
[[ "${adoption_output}" != *'BEGIN PRIVATE KEY'* ]] || fail "adoption output leaked private-key material"
[[ "${adoption_output}" != *'sensitive-last-applied-marker'* ]] || fail "adoption output leaked the legacy last-applied payload"
if rg -Fq -- 'private-test-value|BEGIN PRIVATE KEY|sensitive-last-applied-marker' \
  "${work}/secret-store/argv.log" "${work}/kube-store/argv.log"; then
  fail "adoption exposed Secret bytes in child-process arguments"
fi
stdin_upload_count="$(rg -F -- '--data-file=-' "${work}/secret-store/argv.log" | wc -l | tr -d ' ')"
# Eight successful writes plus the deliberately failed third attempt above.
[[ "${stdin_upload_count}" == 9 ]] || fail "adoption made ${stdin_upload_count} stdin upload attempts; expected nine"
[[ -z "$(find "${runtime_tmp}" -type f -print -quit)" ]] || fail "adoption left a file in its runtime temporary directory"

# A complete rerun must read and compare the single exact enabled version for
# every target, perform no upload, preserve Secret data and keep annotations
# absent.
version_count_before="$(wc -l < "${work}/secret-store/versions-add.log" | tr -d ' ')"
rerun_output="$(
  PATH="${work}/mock-bin:${PATH}" \
  TMPDIR="${runtime_tmp}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  "${bootstrap}" adopt-existing --project test-project --context test-context 2>&1
)"
[[ "$(wc -l < "${work}/secret-store/versions-add.log" | tr -d ' ')" == "${version_count_before}" ]] || fail "idempotent adoption created an extra Secret Manager version"
assert_last_applied_count 0
snapshot_secret_data "${work}/after-rerun.sha256"
cmp -s "${work}/before-adoption.sha256" "${work}/after-rerun.sha256" || fail "idempotent adoption changed native Kubernetes Secret bytes"
[[ "${rerun_output}" != *'private-test-value'* && "${rerun_output}" != *'BEGIN PRIVATE KEY'* ]] || fail "idempotent adoption output leaked Secret bytes"

printf 'substrate existing Secret adoption tests passed\n'
