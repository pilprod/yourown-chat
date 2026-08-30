#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail
umask 077

readonly credential_path="/var/run/substrate-enrollment/private/enrollment-credential"
readonly policy_mount_path="/var/run/substrate-policy/slot-policy.yaml"
readonly token_path="/var/run/secrets/substrate/token"
readonly server_ca_path="/var/run/secrets/substrate-ca/server-ca.pem"
readonly wait_timeout_seconds=600

usage() {
  cat <<'EOF'
Issue one scoped Substrate external-provider enrollment from an ephemeral,
restricted in-cluster Pod. The credential is never sent through Terraform,
a Kubernetes Secret, Pod logs, or a port-forward.

Usage:
  issue-substrate-external-provider-enrollment.sh \
    --kubectl-ate-image REGISTRY/REPOSITORY@sha256:DIGEST \
    --transfer-image REGISTRY/REPOSITORY@sha256:DIGEST \
    --context KUBERNETES_CONTEXT \
    --namespace SUBSTRATE_NAMESPACE \
    --service-account ENROLLMENT_ADMIN_SERVICE_ACCOUNT \
    --api-endpoint api.SUBSTRATE_NAMESPACE.svc:443 \
    --server-name api.SUBSTRATE_NAMESPACE.svc \
    --ca-secret SECRET_WITH_SERVER_CA_PEM \
    --owner-atespace OWNER \
    --worker-namespace WORKER_NAMESPACE \
    --worker-pool WORKER_POOL \
    --max-slots 1..256 \
    --policy-file /absolute/owner-only/slot-policy.yaml \
    --ttl INTEGER[s|m|h] \
    --output-file /absolute/owner-only/new-enrollment-file

Both images must be exact sha256 digest references without tags. The transfer
image must be a reviewed, minimal image that provides /bin/sh, sleep, test,
mkdir, chmod, and cat and can run as uid/gid 65532.
EOF
}

fail() {
  printf 'Substrate enrollment bootstrap failed: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local flag="$1"
  local remaining="$2"

  [[ "${remaining}" -ge 2 ]] || fail "${flag} requires one value"
}

require_once() {
  local current="$1"
  local flag="$2"

  [[ -z "${current}" ]] || fail "${flag} was specified more than once"
}

validate_digest_image() {
  local value="$1"
  local flag="$2"
  local image_pattern='^[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+@sha256:[0-9a-f]{64}$'

  [[ "${value}" =~ ${image_pattern} ]] ||
    fail "${flag} must be an exact lowercase OCI sha256 digest reference without a tag"
}

validate_dns_label() {
  local value="$1"
  local description="$2"
  local label_pattern='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

  [[ ${#value} -le 63 && "${value}" =~ ${label_pattern} ]] ||
    fail "${description} must be one DNS-1123 label"
}

validate_dns_subdomain() {
  local value="$1"
  local description="$2"
  local label
  local labels

  [[ -n "${value}" && ${#value} -le 253 ]] ||
    fail "${description} must be a non-empty DNS-1123 subdomain"
  IFS='.' read -r -a labels <<< "${value}"
  for label in "${labels[@]}"; do
    validate_dns_label "${label}" "${description} component"
  done
}

portable_stat() {
  local path="$1"

  if stat -f '%u %Lp %z' "${path}" 2>/dev/null; then
    return 0
  fi
  stat -c '%u %a %s' "${path}"
}

sha256_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
    return
  fi
  fail "sha256sum or shasum is required"
}

kubectl_ate_image=""
transfer_image=""
kube_context=""
namespace=""
service_account=""
api_endpoint=""
server_name=""
ca_secret=""
owner_atespace=""
worker_namespace=""
worker_pool=""
max_slots=""
policy_file=""
ttl=""
output_file_input=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubectl-ate-image)
      require_value "$1" "$#"
      require_once "${kubectl_ate_image}" "$1"
      kubectl_ate_image="$2"
      shift 2
      ;;
    --transfer-image)
      require_value "$1" "$#"
      require_once "${transfer_image}" "$1"
      transfer_image="$2"
      shift 2
      ;;
    --context)
      require_value "$1" "$#"
      require_once "${kube_context}" "$1"
      kube_context="$2"
      shift 2
      ;;
    --namespace)
      require_value "$1" "$#"
      require_once "${namespace}" "$1"
      namespace="$2"
      shift 2
      ;;
    --service-account)
      require_value "$1" "$#"
      require_once "${service_account}" "$1"
      service_account="$2"
      shift 2
      ;;
    --api-endpoint)
      require_value "$1" "$#"
      require_once "${api_endpoint}" "$1"
      api_endpoint="$2"
      shift 2
      ;;
    --server-name)
      require_value "$1" "$#"
      require_once "${server_name}" "$1"
      server_name="$2"
      shift 2
      ;;
    --ca-secret)
      require_value "$1" "$#"
      require_once "${ca_secret}" "$1"
      ca_secret="$2"
      shift 2
      ;;
    --owner-atespace)
      require_value "$1" "$#"
      require_once "${owner_atespace}" "$1"
      owner_atespace="$2"
      shift 2
      ;;
    --worker-namespace)
      require_value "$1" "$#"
      require_once "${worker_namespace}" "$1"
      worker_namespace="$2"
      shift 2
      ;;
    --worker-pool)
      require_value "$1" "$#"
      require_once "${worker_pool}" "$1"
      worker_pool="$2"
      shift 2
      ;;
    --max-slots)
      require_value "$1" "$#"
      require_once "${max_slots}" "$1"
      max_slots="$2"
      shift 2
      ;;
    --policy-file)
      require_value "$1" "$#"
      require_once "${policy_file}" "$1"
      policy_file="$2"
      shift 2
      ;;
    --ttl)
      require_value "$1" "$#"
      require_once "${ttl}" "$1"
      ttl="$2"
      shift 2
      ;;
    --output-file)
      require_value "$1" "$#"
      require_once "${output_file_input}" "$1"
      output_file_input="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

for required_value in \
  "${kubectl_ate_image}" "${transfer_image}" "${kube_context}" \
  "${namespace}" "${service_account}" "${api_endpoint}" \
  "${server_name}" "${ca_secret}" "${owner_atespace}" \
  "${worker_namespace}" "${worker_pool}" "${max_slots}" \
  "${policy_file}" "${ttl}" "${output_file_input}"; do
  [[ -n "${required_value}" ]] || fail "all documented arguments are required"
done

validate_digest_image "${kubectl_ate_image}" "--kubectl-ate-image"
validate_digest_image "${transfer_image}" "--transfer-image"
[[ ${#kube_context} -le 253 && "${kube_context}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] ||
  fail "--context contains unsupported characters or is too long"
validate_dns_label "${namespace}" "--namespace"
validate_dns_subdomain "${service_account}" "--service-account"
validate_dns_subdomain "${ca_secret}" "--ca-secret"
validate_dns_label "${owner_atespace}" "--owner-atespace"
validate_dns_label "${worker_namespace}" "--worker-namespace"
validate_dns_subdomain "${worker_pool}" "--worker-pool"

expected_server_name="api.${namespace}.svc"
[[ "${api_endpoint}" == "${expected_server_name}:443" ]] ||
  fail "--api-endpoint must be exactly ${expected_server_name}:443"
[[ "${server_name}" == "${expected_server_name}" ]] ||
  fail "--server-name must be exactly ${expected_server_name}"

[[ "${max_slots}" =~ ^[1-9][0-9]{0,2}$ ]] ||
  fail "--max-slots must be an integer between 1 and 256"
(( max_slots <= 256 )) || fail "--max-slots must be an integer between 1 and 256"

[[ "${ttl}" =~ ^([1-9][0-9]{0,7})([smh])$ ]] ||
  fail "--ttl must be a positive integer followed by s, m, or h"
ttl_amount="${BASH_REMATCH[1]}"
ttl_unit="${BASH_REMATCH[2]}"
case "${ttl_unit}" in
  s) ttl_seconds="${ttl_amount}" ;;
  m) ttl_seconds=$((ttl_amount * 60)) ;;
  h) ttl_seconds=$((ttl_amount * 3600)) ;;
  *) fail "unreachable TTL unit" ;;
esac
(( ttl_seconds <= 86400 )) || fail "--ttl must not exceed 24h"

[[ "${policy_file}" == /* ]] || fail "--policy-file must be an absolute path"
[[ "${policy_file}" != *$'\n'* && "${policy_file}" != *$'\r'* ]] ||
  fail "--policy-file must not contain control characters"
[[ -f "${policy_file}" && ! -L "${policy_file}" ]] ||
  fail "--policy-file must be a regular file, not a symlink"

policy_uid=""
policy_mode=""
policy_size=""
if ! IFS=' ' read -r policy_uid policy_mode policy_size < <(portable_stat "${policy_file}"); then
  fail "could not inspect --policy-file"
fi
current_uid="$(id -u)"
[[ "${policy_uid}" == "${current_uid}" ]] ||
  fail "--policy-file must be owned by the invoking user"
[[ "${policy_mode}" == "400" || "${policy_mode}" == "600" ]] ||
  fail "--policy-file mode must be exactly 0400 or 0600"
[[ "${policy_size}" =~ ^[0-9]+$ ]] || fail "could not determine --policy-file size"
(( policy_size > 0 && policy_size <= 524288 )) ||
  fail "--policy-file must be between 1 byte and 512 KiB"

[[ "${output_file_input}" == /* ]] || fail "--output-file must be an absolute path"
[[ "${output_file_input}" != *$'\n'* && "${output_file_input}" != *$'\r'* ]] ||
  fail "--output-file must not contain control characters"
output_basename="${output_file_input##*/}"
[[ -n "${output_basename}" && "${output_basename}" != "." && "${output_basename}" != ".." ]] ||
  fail "--output-file must name a file"
output_parent_input="${output_file_input%/*}"
[[ -n "${output_parent_input}" ]] || output_parent_input="/"
[[ -d "${output_parent_input}" && ! -L "${output_parent_input}" ]] ||
  fail "--output-file parent must be a real directory, not a symlink"
output_parent="$(cd -- "${output_parent_input}" && pwd -P)"
if [[ "${output_parent}" == "/" ]]; then
  output_file="/${output_basename}"
else
  output_file="${output_parent}/${output_basename}"
fi
[[ ! -e "${output_file}" && ! -L "${output_file}" ]] ||
  fail "--output-file already exists; refusing to overwrite it"

output_parent_uid=""
output_parent_mode=""
output_parent_size=""
if ! IFS=' ' read -r output_parent_uid output_parent_mode output_parent_size < <(portable_stat "${output_parent}"); then
  fail "could not inspect --output-file parent"
fi
[[ "${output_parent_uid}" == "${current_uid}" ]] ||
  fail "--output-file parent must be owned by the invoking user"
[[ "${output_parent_mode}" =~ ^[0-7]{3,4}$ ]] ||
  fail "could not determine --output-file parent mode"
output_parent_mode_value=$((8#${output_parent_mode}))
(( (output_parent_mode_value & 077) == 0 )) ||
  fail "--output-file parent must exclude all group and other permissions"
(( (output_parent_mode_value & 0300) == 0300 )) ||
  fail "--output-file parent must be owner-writable and owner-searchable"

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"
command -v awk >/dev/null 2>&1 || fail "awk is required"

scratch_dir=""
local_partial=""
pod_name=""
configmap_name=""
networkpolicy_name=""
pod_may_exist=0
configmap_may_exist=0
networkpolicy_may_exist=0
issuance_may_have_happened=0

cleanup() {
  local status=$?
  local cleanup_failed=0
  local pod_absent=1
  trap - EXIT INT TERM HUP
  set +o errexit

  # A create request can be accepted by the API server even when the client
  # receives an ambiguous failure, so *_may_exist is set before every create.
  # Never remove the isolation policy or policy ConfigMap unless Pod deletion
  # is confirmed successful. A failed deletion leaves the Pod restricted and
  # forces a non-zero exit for operator cleanup.
  if [[ "${pod_may_exist}" -eq 1 ]]; then
    if ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
      delete "pod/${pod_name}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1; then
      pod_absent=0
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not confirm Pod deletion; retaining NetworkPolicy and ConfigMap for safe operator cleanup\n' >&2
    fi
  fi

  if [[ "${pod_absent}" -eq 1 ]]; then
    if [[ "${configmap_may_exist}" -eq 1 ]] &&
      ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
        delete "configmap/${configmap_name}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete the policy ConfigMap\n' >&2
    fi
    if [[ "${networkpolicy_may_exist}" -eq 1 ]] &&
      ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
        delete "networkpolicy/${networkpolicy_name}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete the NetworkPolicy\n' >&2
    fi
  fi
  if [[ -n "${local_partial}" && -f "${local_partial}" ]]; then
    if ! rm -f -- "${local_partial}"; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete the local partial credential file\n' >&2
    fi
  fi
  if [[ -n "${scratch_dir}" && "${scratch_dir}" == /tmp/yourown-chat-enrollment.* && -d "${scratch_dir}" ]]; then
    if ! rm -rf -- "${scratch_dir}"; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete its local scratch directory\n' >&2
    fi
  fi
  if [[ "${cleanup_failed}" -eq 1 && "${status}" -eq 0 ]]; then
    status=1
  fi
  if [[ "${issuance_may_have_happened}" -eq 1 && "${status}" -ne 0 ]]; then
    printf 'Substrate enrollment issuance may already have occurred; DO NOT RETRY automatically; operator review is required\n' >&2
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

scratch_dir="$(mktemp -d /tmp/yourown-chat-enrollment.XXXXXXXX)"
chmod 0700 "${scratch_dir}"
staged_policy="${scratch_dir}/slot-policy.yaml"
policy_sha_before="$(sha256_file "${policy_file}")"
cp -- "${policy_file}" "${staged_policy}"
chmod 0600 "${staged_policy}"
policy_sha_staged="$(sha256_file "${staged_policy}")"
policy_sha_after="$(sha256_file "${policy_file}")"
[[ "${policy_sha_before}" == "${policy_sha_staged}" && "${policy_sha_before}" == "${policy_sha_after}" ]] ||
  fail "--policy-file changed while it was being staged"

kubectl config get-contexts "${kube_context}" --no-headers | grep -q '[^[:space:]]' ||
  fail "--context does not identify an available kubectl context"
kubectl --context="${kube_context}" --request-timeout=30s \
  get namespace "${namespace}" --output=name >/dev/null
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  get serviceaccount "${service_account}" --output=name >/dev/null
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  get secret "${ca_secret}" \
  --output='go-template={{if index .data "server-ca.pem"}}present{{end}}{{"\n"}}' |
  grep -qx 'present' || fail "--ca-secret is missing server-ca.pem"

run_suffix="r$$-${RANDOM}-${RANDOM}"
pod_name="substrate-enrollment-${run_suffix}"
configmap_name="substrate-enrollment-policy-${run_suffix}"
networkpolicy_name="substrate-enrollment-egress-${run_suffix}"

configmap_may_exist=1
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  create configmap "${configmap_name}" \
  --from-file="slot-policy.yaml=${staged_policy}" >/dev/null
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  label configmap "${configmap_name}" \
  app.kubernetes.io/name=substrate-enrollment-admin \
  app.kubernetes.io/component=enrollment-admin \
  app.kubernetes.io/part-of=kagent-substrate-testbed \
  "yourown.chat/enrollment-run=${run_suffix}" >/dev/null
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  annotate configmap "${configmap_name}" \
  "yourown.chat/slot-policy-sha256=${policy_sha_before}" >/dev/null

networkpolicy_may_exist=1
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  create -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${networkpolicy_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: substrate-enrollment-admin
    app.kubernetes.io/component: enrollment-admin
    app.kubernetes.io/part-of: kagent-substrate-testbed
    yourown.chat/enrollment-run: ${run_suffix}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: substrate-enrollment-admin
      app.kubernetes.io/component: enrollment-admin
      app.kubernetes.io/part-of: kagent-substrate-testbed
      yourown.chat/enrollment-run: ${run_suffix}
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: node-local-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app: ate-api-server
      ports:
        - protocol: TCP
          port: 443
EOF

# The API server can accept the Pod while the client sees an ambiguous create
# failure, and the enrollment RPC can issue a credential before any later
# local failure. From this point every non-zero exit carries an explicit
# no-automatic-retry warning from cleanup.
pod_may_exist=1
issuance_may_have_happened=1
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  create -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: substrate-enrollment-admin
    app.kubernetes.io/component: enrollment-admin
    app.kubernetes.io/part-of: kagent-substrate-testbed
    yourown.chat/enrollment-run: ${run_suffix}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: 5
  serviceAccountName: ${service_account}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile:
      type: RuntimeDefault
  volumes:
    - name: handoff
      emptyDir:
        medium: Memory
        sizeLimit: 16Ki
    - name: policy
      configMap:
        name: ${configmap_name}
        defaultMode: 0444
        items:
          - key: slot-policy.yaml
            path: slot-policy.yaml
    - name: substrate-token
      projected:
        defaultMode: 0440
        sources:
          - serviceAccountToken:
              path: token
              audience: ${expected_server_name}
              expirationSeconds: 600
    - name: substrate-server-ca
      secret:
        secretName: ${ca_secret}
        defaultMode: 0444
        items:
          - key: server-ca.pem
            path: server-ca.pem
  initContainers:
    - name: prepare-handoff
      image: ${transfer_image}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -ceu
        - |
          umask 077
          mkdir /var/run/substrate-enrollment/private
          chmod 0700 /var/run/substrate-enrollment/private
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 50m
          memory: 16Mi
      volumeMounts:
        - name: handoff
          mountPath: /var/run/substrate-enrollment
  containers:
    - name: issue-enrollment
      image: ${kubectl_ate_image}
      imagePullPolicy: IfNotPresent
      args:
        - --endpoint
        - ${api_endpoint}
        - --token-file
        - ${token_path}
        - --server-ca-file
        - ${server_ca_path}
        - --server-name
        - ${server_name}
        - admin
        - create
        - external-provider-enrollment
        - --owner-atespace
        - ${owner_atespace}
        - --worker-namespace
        - ${worker_namespace}
        - --worker-pool
        - ${worker_pool}
        - --max-slots
        - "${max_slots}"
        - --slot-policy
        - ${policy_mount_path}
        - --ttl
        - ${ttl}
        - --credential-file
        - ${credential_path}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 250m
          memory: 128Mi
      volumeMounts:
        - name: handoff
          mountPath: /var/run/substrate-enrollment
        - name: policy
          mountPath: /var/run/substrate-policy
          readOnly: true
        - name: substrate-token
          mountPath: /var/run/secrets/substrate
          readOnly: true
        - name: substrate-server-ca
          mountPath: /var/run/secrets/substrate-ca
          readOnly: true
    - name: transfer
      image: ${transfer_image}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -ceu
        - |
          trap 'exit 0' TERM INT
          while [ ! -s ${credential_path} ]; do
            sleep 1
          done
          while :; do
            sleep 3600
          done
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 50m
          memory: 16Mi
      volumeMounts:
        - name: handoff
          mountPath: /var/run/substrate-enrollment
          readOnly: true
EOF

status_file="${scratch_dir}/main-exit-code"
deadline=$((SECONDS + wait_timeout_seconds))
main_exit=""
while (( SECONDS < deadline )); do
  : > "${status_file}"
  if kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
    get "pod/${pod_name}" \
    --output='jsonpath={range .status.containerStatuses[?(@.name=="issue-enrollment")]}{.state.terminated.exitCode}{end}' \
    > "${status_file}"; then
    IFS= read -r main_exit < "${status_file}" || [[ -n "${main_exit}" ]]
    [[ -z "${main_exit}" ]] || break
  fi
  sleep 1
done
[[ -n "${main_exit}" ]] || fail "timed out waiting for the in-cluster enrollment command"
[[ "${main_exit}" == "0" ]] ||
  fail "the in-cluster enrollment command exited unsuccessfully; credential output was not read"

credential_ready=0
while (( SECONDS < deadline )); do
  if kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
    exec "pod/${pod_name}" -c transfer -- test -s "${credential_path}" >/dev/null 2>&1; then
    credential_ready=1
    break
  fi
  sleep 1
done
[[ "${credential_ready}" -eq 1 ]] || fail "the enrollment command succeeded without a readable credential handoff"

local_partial="$(mktemp "${output_file}.partial.XXXXXXXX")"
chmod 0600 "${local_partial}"
# Keep the credential stream out of command substitution and every diagnostic.
if ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  exec "pod/${pod_name}" -c transfer -- cat "${credential_path}" > "${local_partial}"; then
  fail "credential transfer failed or was ambiguous after enrollment issuance"
fi

partial_uid=""
partial_mode=""
partial_size=""
if ! IFS=' ' read -r partial_uid partial_mode partial_size < <(portable_stat "${local_partial}"); then
  fail "could not inspect the transferred credential"
fi
[[ "${partial_uid}" == "${current_uid}" && "${partial_mode}" == "600" ]] ||
  fail "the transferred credential does not have exact owner-only ownership and mode"
[[ "${partial_size}" =~ ^[0-9]+$ ]] || fail "could not determine transferred credential size"
(( partial_size > 0 && partial_size <= 4096 )) ||
  fail "the transferred enrollment credential has an invalid size"
if LC_ALL=C tr -d 'A-Za-z0-9_-' < "${local_partial}" | grep -q .; then
  fail "the transferred enrollment credential has invalid characters"
fi

# A same-directory hard link atomically publishes a new name and cannot replace
# a destination created after the initial preflight check.
if ! ln "${local_partial}" "${output_file}"; then
  fail "could not atomically publish --output-file without overwriting a path"
fi
rm -f -- "${local_partial}"
local_partial=""

printf 'Substrate external-provider enrollment credential written to %s\n' "${output_file}"
