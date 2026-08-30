#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
repo_root="$(cd "${app_dir}/../.." && pwd -P)"
subject="${app_dir}/scripts/issue-substrate-external-provider-enrollment.sh"
substrate_values="${repo_root}/helm/kagent/substrate.values.yaml"
substrate_prerequisites="${app_dir}/modules/substrate-prerequisites/main.tf"

fail() {
  printf 'substrate external-provider enrollment test failed: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"

  grep -Fq -- "${literal}" "${file}" || fail "${file} is missing: ${literal}"
}

forbid_pattern() {
  local file="$1"
  local pattern="$2"

  if grep -Eq -- "${pattern}" "${file}"; then
    fail "${file} contains forbidden pattern: ${pattern}"
  fi
}

file_mode() {
  local file="$1"
  local output

  if output="$(stat -f '%Lp' "${file}" 2>/dev/null)"; then
    printf '%s\n' "${output}"
    return
  fi
  stat -c '%a' "${file}"
}

repeat_hex() {
  local character="$1"

  printf '%64s' '' | tr ' ' "${character}"
}

temporary_dir="$(mktemp -d)"
trap 'rm -rf "${temporary_dir}"' EXIT
fake_bin="${temporary_dir}/bin"
private_dir="${temporary_dir}/private"
mkdir -p "${fake_bin}" "${private_dir}"
chmod 0700 "${private_dir}"
real_stat_command="$(command -v stat)"

policy_file="${private_dir}/slot-policy.yaml"
printf '%s\n' \
  'version: 1' \
  'profiles:' \
  '- profileId: codex-native' \
  '  sandboxClass: host-process-hardened' \
  '  maxSlots: 2' \
  '  capacity:' \
  '    cpuMilli: 2000' \
  '    memoryBytes: 4294967296' > "${policy_file}"
chmod 0600 "${policy_file}"

cat > "${fake_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

log_dir="${FAKE_KUBECTL_LOG_DIR:?}"
mkdir -p "${log_dir}"
{
  printf 'kubectl'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${log_dir}/calls.log"

all_args="$*"
if [[ "${all_args}" == *' delete pod/'* && "${FAKE_POD_DELETE_FAIL:-0}" == 1 ]]; then
  exit 75
fi
if [[ "${all_args}" == config\ get-contexts* ]]; then
  printf '%s\n' 'fixture-context'
  exit 0
fi
if [[ "${all_args}" == *'--namespace=kube-system'* && "${all_args}" == *' get service kube-dns '* ]]; then
  printf '%s' '10.3.240.10'
  exit 0
fi
if [[ "${all_args}" == *' get secret '* ]]; then
  printf '%s\n' 'present'
  exit 0
fi
if [[ "${all_args}" == *' get networkpolicy substrate-enrollment-admin-default-deny '* ]]; then
  printf '%s\n' "${FAKE_PERSISTENT_POLICY_CONTRACT:-substrate-enrollment-admin|enrollment-admin|kagent-substrate-testbed|3|0|Ingress,Egress,|0|0}"
  exit 0
fi
if [[ "${all_args}" == *' create configmap '* ]]; then
  for argument in "$@"; do
    case "${argument}" in
      --from-file=slot-policy.yaml=*)
        cp "${argument#--from-file=slot-policy.yaml=}" "${log_dir}/configmap-policy.yaml"
        ;;
    esac
  done
  exit 0
fi
if [[ "${all_args}" == *' create -f -'* ]]; then
  manifest="${log_dir}/incoming.$$.yaml"
  while IFS= read -r line; do
    printf '%s\n' "${line}" >> "${manifest}"
  done
  kind="$(awk '/^kind: / {print $2; exit}' "${manifest}")"
  case "${kind}" in
    NetworkPolicy) cp "${manifest}" "${log_dir}/networkpolicy.yaml" ;;
    Pod) cp "${manifest}" "${log_dir}/pod.yaml" ;;
    *) exit 91 ;;
  esac
  exit 0
fi
if [[ "${all_args}" == *' get pod/'* && "${all_args}" == *'jsonpath='* ]]; then
  printf '%s\n' "${FAKE_MAIN_EXIT_CODE:-0}"
  exit 0
fi
if [[ "${all_args}" == *' exec pod/'* && "${all_args}" == *' -- test -s '* ]]; then
  [[ "${FAKE_CREDENTIAL_READY:-1}" == 1 ]]
  exit
fi
if [[ "${all_args}" == *' exec pod/'* && "${all_args}" == *' -- cat '* ]]; then
  [[ "${FAKE_CAT_FAIL:-0}" != 1 ]] || exit 76
  case "${FAKE_CREDENTIAL_MODE:-valid}" in
    valid) printf '%s' "${FAKE_CREDENTIAL:-enrollment_A1-b2}" ;;
    newline) printf '\n' ;;
    carriage-return) printf 'enrollment\rA1' ;;
    nul) printf 'enrollment\000A1' ;;
    *) exit 92 ;;
  esac
  exit 0
fi
exit 0
EOF
chmod 0755 "${fake_bin}/kubectl"

cat > "${fake_bin}/stat" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

if [[ "$1" == -f ]]; then
  printf '%s\n' 'File: simulated GNU stat probe output'
  exit 1
fi
if [[ "$1" == -c ]]; then
  format="$2"
  path="$3"
  if output="$("${REAL_STAT:?}" -c "${format}" "${path}" 2>/dev/null)"; then
    :
  else
    case "${format}" in
      '%u %a %s') output="$("${REAL_STAT}" -f '%u %Lp %z' "${path}")" ;;
      '%a') output="$("${REAL_STAT}" -f '%Lp' "${path}")" ;;
      *) exit 93 ;;
    esac
  fi
  printf '%s\n' "${output}"
  if [[ "${FAKE_POLICY_SWAP_ON_PIN_STAT:-0}" == 1 &&
    "${path}" == *'/.yourown-chat-policy-stage.'*'/source' &&
    ! -e "${FAKE_POLICY_SWAP_MARKER:?}" ]]; then
    mv "${FAKE_POLICY_REPLACEMENT:?}" "${FAKE_POLICY_FILE:?}"
    : > "${FAKE_POLICY_SWAP_MARKER}"
  fi
  exit 0
fi
exec "${REAL_STAT:?}" "$@"
EOF
chmod 0755 "${fake_bin}/stat"

digest_a="sha256:$(repeat_hex a)"
digest_b="sha256:$(repeat_hex b)"
valid_kubectl_image="ghcr.io/pilprod/substrate/kubectl-ate@${digest_a}"
valid_transfer_image="registry.k8s.io/busybox@${digest_b}"

invoke_subject() {
  local destination="$1"

  PATH="${fake_bin}:${PATH}" \
  REAL_STAT="${real_stat_command}" \
  FAKE_KUBECTL_LOG_DIR="${FAKE_KUBECTL_LOG_DIR}" \
  FAKE_MAIN_EXIT_CODE="${FAKE_MAIN_EXIT_CODE:-0}" \
  FAKE_CREDENTIAL_READY="${FAKE_CREDENTIAL_READY:-1}" \
  FAKE_CREDENTIAL="${FAKE_CREDENTIAL:-enrollment_A1-b2}" \
  FAKE_CREDENTIAL_MODE="${FAKE_CREDENTIAL_MODE:-valid}" \
  FAKE_PERSISTENT_POLICY_CONTRACT="${FAKE_PERSISTENT_POLICY_CONTRACT:-substrate-enrollment-admin|enrollment-admin|kagent-substrate-testbed|3|0|Ingress,Egress,|0|0}" \
  FAKE_POD_DELETE_FAIL="${FAKE_POD_DELETE_FAIL:-0}" \
  FAKE_CAT_FAIL="${FAKE_CAT_FAIL:-0}" \
  FAKE_POLICY_SWAP_ON_PIN_STAT="${FAKE_POLICY_SWAP_ON_PIN_STAT:-0}" \
  FAKE_POLICY_SWAP_MARKER="${FAKE_POLICY_SWAP_MARKER:-${temporary_dir}/unused-policy-swap-marker}" \
  FAKE_POLICY_REPLACEMENT="${FAKE_POLICY_REPLACEMENT:-${temporary_dir}/unused-policy-replacement}" \
  FAKE_POLICY_FILE="${FAKE_POLICY_FILE:-${policy_file}}" \
    "${subject}" \
    --kubectl-ate-image "${KUBECTL_IMAGE:-${valid_kubectl_image}}" \
    --transfer-image "${TRANSFER_IMAGE:-${valid_transfer_image}}" \
    --context "${KUBE_CONTEXT:-gke_fixture}" \
    --cluster-dns-ip "${CLUSTER_DNS_IP:-10.3.240.10}" \
    --namespace "${NAMESPACE:-ate-system}" \
    --service-account "${SERVICE_ACCOUNT:-ate-enrollment-admin}" \
    --api-endpoint "${API_ENDPOINT:-api.ate-system.svc:443}" \
    --server-name "${SERVER_NAME:-api.ate-system.svc}" \
    --ca-secret "${CA_SECRET:-substrate-ate-controller-tls}" \
    --owner-atespace "${OWNER_ATESPACE:-tenant-a}" \
    --worker-namespace "${WORKER_NAMESPACE:-external-workers}" \
    --worker-pool "${WORKER_POOL:-local-agents}" \
    --max-slots "${MAX_SLOTS:-2}" \
    --policy-file "${POLICY_FILE:-${policy_file}}" \
    --ttl "${TTL:-1h}" \
    --output-file "${destination}"
}

expect_failure() {
  local label="$1"
  local expected="$2"
  local destination="$3"
  local stdout_file="${temporary_dir}/${label}.stdout"
  local stderr_file="${temporary_dir}/${label}.stderr"

  if invoke_subject "${destination}" > "${stdout_file}" 2> "${stderr_file}"; then
    fail "${label} unexpectedly succeeded"
  fi
  [[ ! -e "${destination}" ]] || fail "${label} published an output file"
  require_literal "${stderr_file}" "${expected}"
}

bash -n "${subject}"
bash -n "${BASH_SOURCE[0]}"

success_log="${temporary_dir}/success-log"
mkdir -p "${success_log}"
success_output="${private_dir}/enrollment-token"
FAKE_KUBECTL_LOG_DIR="${success_log}" invoke_subject "${success_output}" \
  > "${temporary_dir}/success.stdout" 2> "${temporary_dir}/success.stderr"

[[ -f "${success_output}" ]] || fail "valid invocation did not publish the credential"
[[ "$(PATH="${fake_bin}:${PATH}" REAL_STAT="${real_stat_command}" file_mode "${success_output}")" == 600 ]] ||
  fail "published credential mode is not 0600"
[[ "$(<"${success_output}")" == 'enrollment_A1-b2' ]] || fail "published credential bytes changed"
success_output_canonical="$(cd "${private_dir}" && pwd -P)/enrollment-token"
require_literal "${temporary_dir}/success.stdout" "Substrate external-provider enrollment credential written to ${success_output_canonical}"
forbid_pattern "${temporary_dir}/success.stdout" 'enrollment_A1-b2'
forbid_pattern "${temporary_dir}/success.stderr" 'enrollment_A1-b2'
forbid_pattern "${success_log}/calls.log" 'enrollment_A1-b2'

pod_manifest="${success_log}/pod.yaml"
networkpolicy_manifest="${success_log}/networkpolicy.yaml"
require_literal "${pod_manifest}" 'kind: Pod'
require_literal "${pod_manifest}" "image: ${valid_kubectl_image}"
[[ "$(grep -Fc -- "image: ${valid_transfer_image}" "${pod_manifest}")" -eq 2 ]] ||
  fail "transfer image must be pinned for init and transfer containers"
require_literal "${pod_manifest}" 'serviceAccountName: ate-enrollment-admin'
require_literal "${pod_manifest}" 'activeDeadlineSeconds: 900'
require_literal "${pod_manifest}" 'automountServiceAccountToken: false'
require_literal "${pod_manifest}" 'enableServiceLinks: false'
require_literal "${pod_manifest}" 'medium: Memory'
require_literal "${pod_manifest}" 'audience: api.ate-system.svc'
require_literal "${pod_manifest}" 'secretName: substrate-ate-controller-tls'
require_literal "${pod_manifest}" '        - --endpoint'
require_literal "${pod_manifest}" '        - api.ate-system.svc:443'
require_literal "${pod_manifest}" '        - --server-ca-file'
require_literal "${pod_manifest}" '        - --server-name'
require_literal "${pod_manifest}" '        - external-provider-enrollment'
require_literal "${pod_manifest}" '        - --credential-file'
require_literal "${pod_manifest}" '        - /var/run/substrate-enrollment/private/enrollment-credential'
require_literal "${pod_manifest}" '          while [ ! -s /var/run/substrate-enrollment/private/enrollment-credential ]; do'
require_literal "${pod_manifest}" '    seccompProfile:'
[[ "$(grep -Fc '        allowPrivilegeEscalation: false' "${pod_manifest}")" -eq 3 ]] ||
  fail "all three container roles must disable privilege escalation"
[[ "$(grep -Fc '        readOnlyRootFilesystem: true' "${pod_manifest}")" -eq 3 ]] ||
  fail "all three container roles must use read-only root filesystems"
[[ "$(grep -Fc '        runAsNonRoot: true' "${pod_manifest}")" -eq 3 ]] ||
  fail "all three container roles must run non-root"
awk '
  $0 == "    - name: transfer" { in_transfer = 1 }
  in_transfer && $0 == "      volumeMounts:" { in_mounts = 1 }
  in_mounts && $0 == "        - name: handoff" { in_handoff = 1 }
  in_handoff && $0 == "          readOnly: true" { found = 1 }
  END { exit(found ? 0 : 1) }
' "${pod_manifest}" || fail "transfer sidecar must mount the credential handoff read-only"
forbid_pattern "${pod_manifest}" '^kind: Secret$'
forbid_pattern "${pod_manifest}" 'enrollment_A1-b2'

require_literal "${networkpolicy_manifest}" 'kind: NetworkPolicy'
require_literal "${networkpolicy_manifest}" '  ingress: []'
require_literal "${networkpolicy_manifest}" '              k8s-app: kube-dns'
require_literal "${networkpolicy_manifest}" '              k8s-app: node-local-dns'
require_literal "${networkpolicy_manifest}" '              app: ate-api-server'
require_literal "${networkpolicy_manifest}" '            cidr: 10.3.240.10/32'
[[ "$(grep -Ec '^[[:space:]]+port: 53$' "${networkpolicy_manifest}")" -eq 6 ]] ||
  fail "NetworkPolicy DNS ports changed"
[[ "$(grep -Ec '^[[:space:]]+port: 443$' "${networkpolicy_manifest}")" -eq 1 ]] ||
  fail "NetworkPolicy ate-api port changed"
[[ "$(grep -Fc '        - ipBlock:' "${networkpolicy_manifest}")" -eq 1 ]] ||
  fail "NetworkPolicy must contain exactly one DNS ClusterIP rule"
forbid_pattern "${networkpolicy_manifest}" 'except:|0\.0\.0\.0/0|::/0'

require_literal "${success_log}/calls.log" 'delete> <pod/substrate-enrollment-'
require_literal "${success_log}/calls.log" 'delete> <configmap/substrate-enrollment-policy-'
require_literal "${success_log}/calls.log" 'delete> <networkpolicy/substrate-enrollment-egress-'
require_literal "${success_log}/calls.log" 'exec> <pod/substrate-enrollment-'
require_literal "${success_log}/calls.log" '--> <cat> </var/run/substrate-enrollment/private/enrollment-credential>'
require_literal "${success_log}/calls.log" '<--namespace=kube-system> <--request-timeout=30s> <get> <service> <kube-dns>'
require_literal "${success_log}/calls.log" '<get> <networkpolicy> <substrate-enrollment-admin-default-deny>'
awk '
  /<get> <networkpolicy> <substrate-enrollment-admin-default-deny>/ { preflight = NR }
  /<create> <configmap>/ { create = NR }
  END { exit(preflight > 0 && create > preflight ? 0 : 1) }
' "${success_log}/calls.log" || fail "persistent default-deny preflight must precede ephemeral resource creation"

require_literal "${substrate_values}" 'app.kubernetes.io/name: substrate-enrollment-admin'
require_literal "${substrate_values}" 'app.kubernetes.io/component: enrollment-admin'
require_literal "${substrate_values}" 'app.kubernetes.io/part-of: kagent-substrate-testbed'
forbid_pattern "${subject}" 'kubectl[^\n]*port-forward|0\.0\.0\.0/0|::/0'
require_literal "${subject}" 'cidr: ${cluster_dns_ip}/32'
forbid_pattern "${subject}" '\$\(kubectl[^)]*cat'
require_literal "${subject}" 'ln "${local_partial}" "${output_file}"'
require_literal "${subject}" 'mode must be exactly 0400 or 0600'
require_literal "${subject}" 'must be owned by the invoking user'
require_literal "${subject}" 'ln -P "${policy_file}" "${policy_anchor}"'
forbid_pattern "${subject}" 'sha256_file "\$\{policy_file\}"|cp -- "\$\{policy_file\}"'
require_literal "${substrate_prerequisites}" 'resource "kubernetes_network_policy_v1" "enrollment_admin_default_deny"'
require_literal "${substrate_prerequisites}" 'name      = "substrate-enrollment-admin-default-deny"'
require_literal "${substrate_prerequisites}" 'policy_types = ["Ingress", "Egress"]'

failure_log="${temporary_dir}/main-failure-log"
mkdir -p "${failure_log}"
failure_output="${private_dir}/failed-enrollment-token"
FAKE_KUBECTL_LOG_DIR="${failure_log}" FAKE_MAIN_EXIT_CODE=7 \
  expect_failure main-exit 'in-cluster enrollment command exited unsuccessfully' "${failure_output}"
require_literal "${failure_log}/calls.log" 'delete> <pod/substrate-enrollment-'
require_literal "${failure_log}/calls.log" 'delete> <configmap/substrate-enrollment-policy-'
require_literal "${failure_log}/calls.log" 'delete> <networkpolicy/substrate-enrollment-egress-'
require_literal "${temporary_dir}/main-exit.stderr" 'DO NOT RETRY automatically; operator review is required'

transfer_failure_log="${temporary_dir}/transfer-failure-log"
mkdir -p "${transfer_failure_log}"
FAKE_KUBECTL_LOG_DIR="${transfer_failure_log}" FAKE_CAT_FAIL=1 \
  expect_failure transfer-failure 'credential transfer failed or was ambiguous after enrollment issuance' "${private_dir}/transfer-failure-token"
require_literal "${temporary_dir}/transfer-failure.stderr" 'DO NOT RETRY automatically; operator review is required'

cleanup_failure_log="${temporary_dir}/cleanup-failure-log"
mkdir -p "${cleanup_failure_log}"
cleanup_failure_output="${private_dir}/cleanup-failure-token"
if FAKE_KUBECTL_LOG_DIR="${cleanup_failure_log}" FAKE_POD_DELETE_FAIL=1 \
  invoke_subject "${cleanup_failure_output}" \
  > "${temporary_dir}/cleanup-failure.stdout" \
  2> "${temporary_dir}/cleanup-failure.stderr"; then
  fail "Pod cleanup failure unexpectedly returned success"
fi
[[ -f "${cleanup_failure_output}" ]] ||
  fail "successfully transferred credential was lost when cleanup failed"
require_literal "${temporary_dir}/cleanup-failure.stderr" 'could not confirm Pod deletion; retaining NetworkPolicy and ConfigMap'
require_literal "${temporary_dir}/cleanup-failure.stderr" 'DO NOT RETRY automatically; operator review is required'
require_literal "${cleanup_failure_log}/calls.log" 'delete> <pod/substrate-enrollment-'
forbid_pattern "${cleanup_failure_log}/calls.log" 'delete> <configmap/substrate-enrollment-policy-'
forbid_pattern "${cleanup_failure_log}/calls.log" 'delete> <networkpolicy/substrate-enrollment-egress-'
forbid_pattern "${temporary_dir}/cleanup-failure.stdout" 'enrollment_A1-b2'
forbid_pattern "${temporary_dir}/cleanup-failure.stderr" 'enrollment_A1-b2'

newline_log="${temporary_dir}/newline-credential-log"
mkdir -p "${newline_log}"
FAKE_KUBECTL_LOG_DIR="${newline_log}" FAKE_CREDENTIAL_MODE=newline \
  expect_failure newline-credential 'transferred enrollment credential has invalid characters' "${private_dir}/newline-credential"
require_literal "${temporary_dir}/newline-credential.stderr" 'DO NOT RETRY automatically; operator review is required'

carriage_return_log="${temporary_dir}/carriage-return-credential-log"
mkdir -p "${carriage_return_log}"
FAKE_KUBECTL_LOG_DIR="${carriage_return_log}" FAKE_CREDENTIAL_MODE=carriage-return \
  expect_failure carriage-return-credential 'transferred enrollment credential has invalid characters' "${private_dir}/carriage-return-credential"

nul_log="${temporary_dir}/nul-credential-log"
mkdir -p "${nul_log}"
FAKE_KUBECTL_LOG_DIR="${nul_log}" FAKE_CREDENTIAL_MODE=nul \
  expect_failure nul-credential 'transferred enrollment credential has invalid characters' "${private_dir}/nul-credential"

validation_log="${temporary_dir}/validation-log"
mkdir -p "${validation_log}"
export FAKE_KUBECTL_LOG_DIR="${validation_log}"

KUBECTL_IMAGE='ghcr.io/pilprod/substrate/kubectl-ate:v0.0.22' \
  expect_failure tagged-kubectl '--kubectl-ate-image must be an exact' "${private_dir}/tagged-kubectl"
TRANSFER_IMAGE='registry.k8s.io/busybox:1.37' \
  expect_failure tagged-transfer '--transfer-image must be an exact' "${private_dir}/tagged-transfer"
NAMESPACE='Bad_Namespace' \
  expect_failure bad-namespace '--namespace must be one DNS-1123 label' "${private_dir}/bad-namespace"
API_ENDPOINT='10.0.0.1:443' \
  expect_failure wrong-endpoint '--api-endpoint must be exactly api.ate-system.svc:443' "${private_dir}/wrong-endpoint"
SERVER_NAME='unexpected.example' \
  expect_failure wrong-sni '--server-name must be exactly api.ate-system.svc' "${private_dir}/wrong-sni"
CLUSTER_DNS_IP='010.3.240.10' \
  expect_failure invalid-cluster-dns '--cluster-dns-ip must be one canonical IPv4 address' "${private_dir}/invalid-cluster-dns"
MAX_SLOTS=257 \
  expect_failure excessive-slots '--max-slots must be an integer between 1 and 256' "${private_dir}/excessive-slots"
TTL=25h \
  expect_failure excessive-ttl '--ttl must not exceed 24h' "${private_dir}/excessive-ttl"

chmod 0644 "${policy_file}"
expect_failure open-policy '--policy-file mode must be exactly 0400 or 0600' "${private_dir}/open-policy"
chmod 0600 "${policy_file}"

policy_link="${private_dir}/policy-link.yaml"
ln -s "${policy_file}" "${policy_link}"
POLICY_FILE="${policy_link}" \
  expect_failure symlink-policy '--policy-file must be a regular file, not a symlink' "${private_dir}/symlink-policy"

open_policy_parent="${temporary_dir}/open-policy-parent"
mkdir "${open_policy_parent}"
chmod 0750 "${open_policy_parent}"
open_parent_policy="${open_policy_parent}/slot-policy.yaml"
printf '%s\n' 'version: 1' > "${open_parent_policy}"
chmod 0600 "${open_parent_policy}"
POLICY_FILE="${open_parent_policy}" \
  expect_failure open-policy-parent '--policy-file parent must exclude all group and other permissions' "${private_dir}/open-policy-parent"

existing_output="${private_dir}/existing-token"
printf '%s' 'do-not-overwrite' > "${existing_output}"
if FAKE_KUBECTL_LOG_DIR="${validation_log}" invoke_subject "${existing_output}" \
  > "${temporary_dir}/existing.stdout" 2> "${temporary_dir}/existing.stderr"; then
  fail "existing output unexpectedly succeeded"
fi
[[ "$(<"${existing_output}")" == 'do-not-overwrite' ]] || fail "existing output was overwritten"
require_literal "${temporary_dir}/existing.stderr" 'already exists; refusing to overwrite it'

open_parent="${temporary_dir}/open-parent"
mkdir "${open_parent}"
chmod 0750 "${open_parent}"
expect_failure open-parent 'parent must exclude all group and other permissions' "${open_parent}/token"

[[ ! -s "${validation_log}/calls.log" ]] ||
  fail "local validation adversaries reached kubectl"

dns_mismatch_log="${temporary_dir}/dns-mismatch-log"
mkdir -p "${dns_mismatch_log}"
FAKE_KUBECTL_LOG_DIR="${dns_mismatch_log}" CLUSTER_DNS_IP='10.3.240.11' \
  expect_failure mismatched-cluster-dns '--cluster-dns-ip does not match kube-system/kube-dns ClusterIP' "${private_dir}/mismatched-cluster-dns"
require_literal "${dns_mismatch_log}/calls.log" '<get> <service> <kube-dns>'
forbid_pattern "${dns_mismatch_log}/calls.log" '<create>'

persistent_policy_mismatch_log="${temporary_dir}/persistent-policy-mismatch-log"
mkdir -p "${persistent_policy_mismatch_log}"
FAKE_KUBECTL_LOG_DIR="${persistent_policy_mismatch_log}" FAKE_PERSISTENT_POLICY_CONTRACT='wrong' \
  expect_failure persistent-policy-mismatch 'persistent enrollment default-deny NetworkPolicy does not match' "${private_dir}/persistent-policy-mismatch"
require_literal "${persistent_policy_mismatch_log}/calls.log" '<get> <networkpolicy> <substrate-enrollment-admin-default-deny>'
forbid_pattern "${persistent_policy_mismatch_log}/calls.log" '<create>'

replacement_policy="${private_dir}/replacement-policy.yaml"
printf '%s\n' 'version: attacker-controlled-replacement' > "${replacement_policy}"
chmod 0600 "${replacement_policy}"
swap_marker="${temporary_dir}/policy-swap.marker"
swap_log="${temporary_dir}/policy-swap-log"
mkdir -p "${swap_log}"
FAKE_KUBECTL_LOG_DIR="${swap_log}" \
FAKE_POLICY_SWAP_ON_PIN_STAT=1 \
FAKE_POLICY_SWAP_MARKER="${swap_marker}" \
FAKE_POLICY_REPLACEMENT="${replacement_policy}" \
FAKE_POLICY_FILE="${policy_file}" \
  invoke_subject "${private_dir}/policy-swap-token" \
  > "${temporary_dir}/policy-swap.stdout" 2> "${temporary_dir}/policy-swap.stderr"
[[ -e "${swap_marker}" ]] || fail "policy replacement adversary did not run"
require_literal "${swap_log}/configmap-policy.yaml" 'profileId: codex-native'
forbid_pattern "${swap_log}/configmap-policy.yaml" 'attacker-controlled-replacement'

printf 'substrate external-provider no-port-forward enrollment tests passed\n'
