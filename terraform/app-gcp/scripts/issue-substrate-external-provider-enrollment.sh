#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail
umask 077

readonly credential_path="/var/run/substrate-enrollment/private/enrollment-credential"
readonly policy_mount_path="/var/run/substrate-policy/slot-policy.yaml"
readonly token_path="/var/run/secrets/substrate/token"
readonly server_ca_path="/var/run/secrets/substrate-ca/server-ca.pem"
readonly wait_timeout_seconds=600
readonly persistent_networkpolicy_name="substrate-enrollment-admin-default-deny"
readonly kubectl_ate_release_repository="github.com/pilprod/substrate"
readonly kubectl_ate_release_tag="v0.0.22"
readonly kubectl_ate_release_tag_object="00a6a684cea3b3feea67461cf79347332ec759ef"
readonly kubectl_ate_release_commit="e9ed68e587b56df2aa2a7f0267a744598c4d48b4"
readonly kubectl_ate_checksums_name="kubectl-ate-v0.0.22-checksums.txt"
readonly kubectl_ate_checksums_sha256="f03851b9fa61cf37b2dbf32b2069ee98685603f5b2f4f07e9d1df56f9888a038"
readonly kubectl_ate_checksums_size="422"
readonly kubectl_ate_linux_amd64_sha256="ea43473b1bc144236541d1e9213a375f23f0a1705254332eae5465d500ce7e15"
readonly kubectl_ate_linux_amd64_size="14619282"
readonly kubectl_ate_linux_amd64_binary_sha256="bcefdf7b564233272c299a1182ca905d092426a2fa4b516e7adfe9ed8d9ebc3a"
readonly kubectl_ate_linux_amd64_binary_size="51855522"
readonly kubectl_ate_linux_arm64_sha256="fa6b8356c2745761ebf24e4448960fcc4e067721bcadeec603bb11364f60f211"
readonly kubectl_ate_linux_arm64_size="12892846"
readonly kubectl_ate_linux_arm64_binary_sha256="58276a98cad397865ab4eae838371a6353b1b549b37a62b70443428de5158dce"
readonly kubectl_ate_linux_arm64_binary_size="48627874"
readonly kubectl_ate_binary_path="/var/run/substrate-runtime/bin/kubectl-ate"

usage() {
  cat <<'EOF'
Issue one scoped Substrate external-provider enrollment from an ephemeral,
restricted in-cluster Pod. The credential is never sent through Terraform,
a Kubernetes Secret, Pod logs, or a port-forward.

Usage:
  issue-substrate-external-provider-enrollment.sh \
    (--kubectl-ate-release v0.0.22 | \
     --kubectl-ate-archive /absolute/owner-only/kubectl-ate-v0.0.22-linux-ARCH.tar.gz | \
     --kubectl-ate-image REGISTRY/REPOSITORY@sha256:DIGEST) \
    [--runtime-arch amd64|arm64] \
    --transfer-image REGISTRY/REPOSITORY@sha256:DIGEST \
    --context KUBERNETES_CONTEXT \
    --cluster-dns-ip IPV4 \
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

Exactly one kubectl-ate source is required. The release and owner-supplied
archive modes require --runtime-arch and run the exact pinned v0.0.22 Linux
binary inside the transfer Pod. The release asset metadata, annotated tag
object, verified source commit, and published checksums are all checked before
upload. An existing authenticated compatible gh CLI adds GitHub's signed
immutable-release attestation check without prompting or changing auth. A
supplied archive must be an owner-only regular file and match the same release
digest. Darwin assets are not accepted because the binary executes on Linux.

Every supplied container image must be an exact sha256 digest reference without
a tag. The transfer image must be a reviewed, minimal image that provides
/bin/sh, sleep, test, mkdir, chmod, cat, and sha256sum and can run as uid/gid
65532.
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

validate_ipv4() {
  local value="$1"
  local description="$2"
  local octet
  local octets

  IFS='.' read -r -a octets <<< "${value}"
  [[ "${#octets[@]}" -eq 4 ]] || fail "${description} must be one canonical IPv4 address"
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^(0|[1-9][0-9]{0,2})$ ]] ||
      fail "${description} must be one canonical IPv4 address"
    (( 10#${octet} <= 255 )) || fail "${description} must be one canonical IPv4 address"
  done
}

portable_stat() {
  local path="$1"
  local output

  if output="$(stat -f '%u %Lp %z' "${path}" 2>/dev/null)"; then
    printf '%s\n' "${output}"
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

github_api_to_file() {
  local endpoint="$1"
  local destination="$2"

  if [[ "${github_cli_authenticated}" -eq 1 ]]; then
    GH_PROMPT_DISABLED=1 gh api --hostname github.com "${endpoint}" > "${destination}" ||
      fail "could not read pinned Substrate release metadata from GitHub"
    return
  fi

  curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --fail --location --silent --show-error --connect-timeout 15 --max-time 60 \
    --max-filesize 5242880 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "${destination}" "https://api.github.com/${endpoint}" ||
    fail "could not read pinned Substrate release metadata from GitHub"
}

download_github_release_asset() {
  local asset_name="$1"
  local destination="$2"

  curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --fail --location --silent --show-error --connect-timeout 15 --max-time 300 \
    --max-filesize 67108864 \
    --output "${destination}" \
    "https://github.com/pilprod/substrate/releases/download/${kubectl_ate_release_tag}/${asset_name}" ||
    fail "could not download pinned Substrate release asset ${asset_name}"
}

verify_release_asset_metadata() {
  local release_json="$1"
  local asset_name="$2"
  local asset_sha256="$3"
  local asset_size="$4"

  jq -e \
    --arg asset "${asset_name}" \
    --arg digest "sha256:${asset_sha256}" \
    --arg tag "${kubectl_ate_release_tag}" \
    --argjson size "${asset_size}" \
    '(.id == 379407334 and
      .tag_name == $tag and
      .target_commitish == "main" and
      .immutable == true and
      .draft == false and
      .prerelease == false and
      .author.login == "pilprod" and
      .author.id == 51009687) and
     (([.assets[] | select(.name == $asset)] | length) == 1) and
     ([.assets[] | select(.name == $asset)][0] |
       .state == "uploaded" and
       .size == $size and
       .digest == $digest and
       .browser_download_url ==
         ("https://github.com/pilprod/substrate/releases/download/" + $tag + "/" + $asset))' \
    "${release_json}" >/dev/null ||
    fail "GitHub release metadata does not match pinned asset ${asset_name}"
}

verify_release_source_identity() {
  local ref_json="$1"
  local tag_json="$2"
  local commit_json="$3"

  jq -e \
    --arg tag "${kubectl_ate_release_tag}" \
    --arg tag_object "${kubectl_ate_release_tag_object}" \
    '.ref == ("refs/tags/" + $tag) and
     .object.type == "tag" and
     .object.sha == $tag_object' "${ref_json}" >/dev/null ||
    fail "Substrate release tag ref does not match the pinned annotated tag"

  jq -e \
    --arg tag "${kubectl_ate_release_tag}" \
    --arg tag_object "${kubectl_ate_release_tag_object}" \
    --arg commit "${kubectl_ate_release_commit}" \
    '.sha == $tag_object and
     .tag == $tag and
     .object.type == "commit" and
     .object.sha == $commit and
     (.verification.signature | type == "string" and length > 0) and
     (.verification.payload | type == "string" and length > 0)' \
    "${tag_json}" >/dev/null ||
    fail "Substrate annotated release tag identity does not match the pinned source"

  jq -e \
    --arg commit "${kubectl_ate_release_commit}" \
    '.sha == $commit and
     .author.login == "pilprod" and
     .author.id == 51009687 and
     .committer.login == "web-flow" and
     .commit.verification.verified == true and
     .commit.verification.reason == "valid"' \
    "${commit_json}" >/dev/null ||
    fail "Substrate release source commit is not the pinned GitHub-verified commit"
}

verify_release_attestation_if_available() {
  local archive="$1"
  local archive_name="$2"
  local archive_sha256="$3"
  local attestation_json="$4"

  if [[ "${github_cli_authenticated}" -ne 1 ]] ||
    ! GH_PROMPT_DISABLED=1 gh release verify-asset --help >/dev/null 2>&1; then
    return
  fi

  GH_PROMPT_DISABLED=1 gh release verify-asset "${kubectl_ate_release_tag}" "${archive}" \
    --repo "${kubectl_ate_release_repository}" --format json > "${attestation_json}" ||
    fail "GitHub's signed immutable-release attestation did not verify the kubectl-ate archive"
  jq -e \
    --arg tag "${kubectl_ate_release_tag}" \
    --arg tag_object "${kubectl_ate_release_tag_object}" \
    --arg asset "${archive_name}" \
    --arg digest "${archive_sha256}" \
    '.verificationResult.signature.certificate.subjectAlternativeName ==
       "https://dotcom.releases.github.com" and
     (.verificationResult.verifiedTimestamps | length) > 0 and
     (.verificationResult.statement |
       .predicateType == "https://in-toto.io/attestation/release/v0.2" and
       .predicate.repository == "pilprod/substrate" and
       .predicate.repositoryId == "1351629720" and
       .predicate.ownerId == "51009687" and
       .predicate.databaseId == "379407334" and
       .predicate.tag == $tag and
       ([.subject[] |
         select(.uri == ("pkg:github/pilprod/substrate@" + $tag) and
           .digest.sha1 == $tag_object)] | length) == 1 and
       ([.subject[] |
         select(.name == $asset and .digest.sha256 == $digest)] | length) == 1)' \
    "${attestation_json}" >/dev/null ||
    fail "GitHub's signed immutable-release attestation has an unexpected identity"
}

kubectl_ate_image=""
kubectl_ate_release=""
kubectl_ate_archive_input=""
runtime_arch=""
transfer_image=""
kube_context=""
cluster_dns_ip=""
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
github_cli_authenticated=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubectl-ate-image)
      require_value "$1" "$#"
      require_once "${kubectl_ate_image}" "$1"
      kubectl_ate_image="$2"
      shift 2
      ;;
    --kubectl-ate-release)
      require_value "$1" "$#"
      require_once "${kubectl_ate_release}" "$1"
      kubectl_ate_release="$2"
      shift 2
      ;;
    --kubectl-ate-archive)
      require_value "$1" "$#"
      require_once "${kubectl_ate_archive_input}" "$1"
      kubectl_ate_archive_input="$2"
      shift 2
      ;;
    --runtime-arch)
      require_value "$1" "$#"
      require_once "${runtime_arch}" "$1"
      runtime_arch="$2"
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
    --cluster-dns-ip)
      require_value "$1" "$#"
      require_once "${cluster_dns_ip}" "$1"
      cluster_dns_ip="$2"
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
  "${transfer_image}" "${kube_context}" \
  "${cluster_dns_ip}" "${namespace}" "${service_account}" "${api_endpoint}" \
  "${server_name}" "${ca_secret}" "${owner_atespace}" \
  "${worker_namespace}" "${worker_pool}" "${max_slots}" \
  "${policy_file}" "${ttl}" "${output_file_input}"; do
  [[ -n "${required_value}" ]] || fail "all documented arguments are required"
done

kubectl_ate_source_count=0
[[ -z "${kubectl_ate_image}" ]] || kubectl_ate_source_count=$((kubectl_ate_source_count + 1))
[[ -z "${kubectl_ate_release}" ]] || kubectl_ate_source_count=$((kubectl_ate_source_count + 1))
[[ -z "${kubectl_ate_archive_input}" ]] || kubectl_ate_source_count=$((kubectl_ate_source_count + 1))
[[ "${kubectl_ate_source_count}" -eq 1 ]] ||
  fail "exactly one of --kubectl-ate-release, --kubectl-ate-archive, or --kubectl-ate-image is required"

kubectl_ate_mode="native"
if [[ -n "${kubectl_ate_image}" ]]; then
  kubectl_ate_mode="image"
  validate_digest_image "${kubectl_ate_image}" "--kubectl-ate-image"
  [[ -z "${runtime_arch}" ]] || fail "--runtime-arch is only valid with a native kubectl-ate source"
else
  [[ -z "${kubectl_ate_release}" || "${kubectl_ate_release}" == "${kubectl_ate_release_tag}" ]] ||
    fail "--kubectl-ate-release must be exactly ${kubectl_ate_release_tag}"
  [[ "${runtime_arch}" == "amd64" || "${runtime_arch}" == "arm64" ]] ||
    fail "--runtime-arch must be exactly amd64 or arm64 for a native kubectl-ate source"
fi
validate_digest_image "${transfer_image}" "--transfer-image"
[[ ${#kube_context} -le 253 && "${kube_context}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] ||
  fail "--context contains unsupported characters or is too long"
validate_ipv4 "${cluster_dns_ip}" "--cluster-dns-ip"
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
current_uid="$(id -u)"
policy_basename="${policy_file##*/}"
[[ -n "${policy_basename}" && "${policy_basename}" != "." && "${policy_basename}" != ".." ]] ||
  fail "--policy-file must name a file"
policy_parent_input="${policy_file%/*}"
[[ -n "${policy_parent_input}" ]] || policy_parent_input="/"
[[ -d "${policy_parent_input}" && ! -L "${policy_parent_input}" ]] ||
  fail "--policy-file parent must be a real directory, not a symlink"
policy_parent="$(cd -- "${policy_parent_input}" && pwd -P)"
if [[ "${policy_parent}" == "/" ]]; then
  policy_file="/${policy_basename}"
else
  policy_file="${policy_parent}/${policy_basename}"
fi

policy_parent_uid=""
policy_parent_mode=""
policy_parent_size=""
if ! IFS=' ' read -r policy_parent_uid policy_parent_mode policy_parent_size < <(portable_stat "${policy_parent}"); then
  fail "could not inspect --policy-file parent"
fi
[[ "${policy_parent_uid}" == "${current_uid}" ]] ||
  fail "--policy-file parent must be owned by the invoking user"
[[ "${policy_parent_mode}" =~ ^[0-7]{3,4}$ ]] ||
  fail "could not determine --policy-file parent mode"
policy_parent_mode_value=$((8#${policy_parent_mode}))
(( (policy_parent_mode_value & 077) == 0 )) ||
  fail "--policy-file parent must exclude all group and other permissions"
(( (policy_parent_mode_value & 0300) == 0300 )) ||
  fail "--policy-file parent must be owner-writable and owner-searchable"

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
if [[ "${kubectl_ate_mode}" == "native" ]]; then
  command -v tar >/dev/null 2>&1 || fail "tar is required for a native kubectl-ate source"
  if [[ -n "${kubectl_ate_release}" ]]; then
    command -v curl >/dev/null 2>&1 || fail "curl is required for --kubectl-ate-release"
    command -v jq >/dev/null 2>&1 || fail "jq is required for --kubectl-ate-release"
    if command -v gh >/dev/null 2>&1 &&
      GH_PROMPT_DISABLED=1 gh auth status --hostname github.com >/dev/null 2>&1; then
      github_cli_authenticated=1
    fi
  fi
fi

scratch_dir=""
policy_stage_dir=""
policy_anchor=""
archive_stage_dir=""
archive_anchor=""
local_partial=""
staged_archive=""
runtime_binary=""
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
  if [[ -n "${policy_anchor}" && -e "${policy_anchor}" ]]; then
    if ! rm -f -- "${policy_anchor}"; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete its pinned policy link\n' >&2
    fi
  fi
  if [[ -n "${policy_stage_dir}" && "${policy_stage_dir}" == "${policy_parent}"/.yourown-chat-policy-stage.* && -d "${policy_stage_dir}" ]]; then
    if ! rmdir -- "${policy_stage_dir}"; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete its policy staging directory\n' >&2
    fi
  fi
  if [[ -n "${archive_anchor}" && -e "${archive_anchor}" ]]; then
    if ! rm -f -- "${archive_anchor}"; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete its pinned kubectl-ate archive link\n' >&2
    fi
  fi
  if [[ -n "${archive_stage_dir}" && -n "${archive_parent:-}" &&
    "${archive_stage_dir}" == "${archive_parent}"/.yourown-chat-kubectl-ate-stage.* && -d "${archive_stage_dir}" ]]; then
    if ! rmdir -- "${archive_stage_dir}"; then
      cleanup_failed=1
      printf 'Substrate enrollment cleanup could not delete its kubectl-ate archive staging directory\n' >&2
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

# Resolve the caller-supplied pathname exactly once by hard-linking it into a
# freshly-created owner-only directory on the same filesystem. Validation and
# copying happen only through that pinned link, eliminating pathname replacement
# between validation and staging on both macOS and Linux.
policy_stage_dir="$(mktemp -d "${policy_parent}/.yourown-chat-policy-stage.XXXXXXXX")"
chmod 0700 "${policy_stage_dir}"
policy_anchor="${policy_stage_dir}/source"
ln -P "${policy_file}" "${policy_anchor}" ||
  fail "could not securely pin --policy-file for staging"
[[ -f "${policy_anchor}" && ! -L "${policy_anchor}" ]] ||
  fail "--policy-file must be a regular file, not a symlink"

policy_uid=""
policy_mode=""
policy_size=""
if ! IFS=' ' read -r policy_uid policy_mode policy_size < <(portable_stat "${policy_anchor}"); then
  fail "could not inspect --policy-file"
fi
[[ "${policy_uid}" == "${current_uid}" ]] ||
  fail "--policy-file must be owned by the invoking user"
[[ "${policy_mode}" == "400" || "${policy_mode}" == "600" ]] ||
  fail "--policy-file mode must be exactly 0400 or 0600"
[[ "${policy_size}" =~ ^[0-9]+$ ]] || fail "could not determine --policy-file size"
(( policy_size > 0 && policy_size <= 524288 )) ||
  fail "--policy-file must be between 1 byte and 512 KiB"

policy_sha_before="$(sha256_file "${policy_anchor}")"
cp -- "${policy_anchor}" "${staged_policy}"
chmod 0600 "${staged_policy}"
policy_sha_staged="$(sha256_file "${staged_policy}")"
policy_sha_after="$(sha256_file "${policy_anchor}")"
[[ "${policy_sha_before}" == "${policy_sha_staged}" && "${policy_sha_before}" == "${policy_sha_after}" ]] ||
  fail "--policy-file changed while it was being staged"
rm -f -- "${policy_anchor}"
policy_anchor=""
rmdir -- "${policy_stage_dir}"
policy_stage_dir=""

if [[ "${kubectl_ate_mode}" == "native" ]]; then
  archive_name="kubectl-ate-${kubectl_ate_release_tag}-linux-${runtime_arch}.tar.gz"
  case "${runtime_arch}" in
    amd64)
      expected_archive_sha256="${kubectl_ate_linux_amd64_sha256}"
      expected_archive_size="${kubectl_ate_linux_amd64_size}"
      expected_binary_sha256="${kubectl_ate_linux_amd64_binary_sha256}"
      expected_binary_size="${kubectl_ate_linux_amd64_binary_size}"
      ;;
    arm64)
      expected_archive_sha256="${kubectl_ate_linux_arm64_sha256}"
      expected_archive_size="${kubectl_ate_linux_arm64_size}"
      expected_binary_sha256="${kubectl_ate_linux_arm64_binary_sha256}"
      expected_binary_size="${kubectl_ate_linux_arm64_binary_size}"
      ;;
    *) fail "unreachable native runtime architecture" ;;
  esac

  staged_archive="${scratch_dir}/${archive_name}"
  runtime_binary="${scratch_dir}/kubectl-ate"

  if [[ -n "${kubectl_ate_archive_input}" ]]; then
    [[ "${kubectl_ate_archive_input}" == /* ]] ||
      fail "--kubectl-ate-archive must be an absolute path"
    [[ "${kubectl_ate_archive_input}" != *$'\n'* && "${kubectl_ate_archive_input}" != *$'\r'* ]] ||
      fail "--kubectl-ate-archive must not contain control characters"
    archive_basename="${kubectl_ate_archive_input##*/}"
    [[ -n "${archive_basename}" && "${archive_basename}" != "." && "${archive_basename}" != ".." ]] ||
      fail "--kubectl-ate-archive must name a file"
    archive_parent_input="${kubectl_ate_archive_input%/*}"
    [[ -n "${archive_parent_input}" ]] || archive_parent_input="/"
    [[ -d "${archive_parent_input}" && ! -L "${archive_parent_input}" ]] ||
      fail "--kubectl-ate-archive parent must be a real directory, not a symlink"
    archive_parent="$(cd -- "${archive_parent_input}" && pwd -P)"
    if [[ "${archive_parent}" == "/" ]]; then
      kubectl_ate_archive="/${archive_basename}"
    else
      kubectl_ate_archive="${archive_parent}/${archive_basename}"
    fi

    archive_parent_uid=""
    archive_parent_mode=""
    archive_parent_size=""
    if ! IFS=' ' read -r archive_parent_uid archive_parent_mode archive_parent_size < <(portable_stat "${archive_parent}"); then
      fail "could not inspect --kubectl-ate-archive parent"
    fi
    [[ "${archive_parent_uid}" == "${current_uid}" ]] ||
      fail "--kubectl-ate-archive parent must be owned by the invoking user"
    [[ "${archive_parent_mode}" =~ ^[0-7]{3,4}$ ]] ||
      fail "could not determine --kubectl-ate-archive parent mode"
    archive_parent_mode_value=$((8#${archive_parent_mode}))
    (( (archive_parent_mode_value & 077) == 0 )) ||
      fail "--kubectl-ate-archive parent must exclude all group and other permissions"
    (( (archive_parent_mode_value & 0300) == 0300 )) ||
      fail "--kubectl-ate-archive parent must be owner-writable and owner-searchable"

    archive_stage_dir="$(mktemp -d "${archive_parent}/.yourown-chat-kubectl-ate-stage.XXXXXXXX")"
    chmod 0700 "${archive_stage_dir}"
    archive_anchor="${archive_stage_dir}/source"
    ln -P "${kubectl_ate_archive}" "${archive_anchor}" ||
      fail "could not securely pin --kubectl-ate-archive for staging"
    [[ -f "${archive_anchor}" && ! -L "${archive_anchor}" ]] ||
      fail "--kubectl-ate-archive must be a regular file, not a symlink"

    archive_uid=""
    archive_mode=""
    archive_size=""
    if ! IFS=' ' read -r archive_uid archive_mode archive_size < <(portable_stat "${archive_anchor}"); then
      fail "could not inspect --kubectl-ate-archive"
    fi
    [[ "${archive_uid}" == "${current_uid}" ]] ||
      fail "--kubectl-ate-archive must be owned by the invoking user"
    [[ "${archive_mode}" == "400" || "${archive_mode}" == "600" ]] ||
      fail "--kubectl-ate-archive mode must be exactly 0400 or 0600"
    [[ "${archive_size}" == "${expected_archive_size}" ]] ||
      fail "--kubectl-ate-archive size does not match ${archive_name}"

    archive_sha_before="$(sha256_file "${archive_anchor}")"
    [[ "${archive_sha_before}" == "${expected_archive_sha256}" ]] ||
      fail "--kubectl-ate-archive digest does not match ${archive_name}"
    cp -- "${archive_anchor}" "${staged_archive}"
    chmod 0600 "${staged_archive}"
    archive_sha_staged="$(sha256_file "${staged_archive}")"
    archive_sha_after="$(sha256_file "${archive_anchor}")"
    [[ "${archive_sha_before}" == "${archive_sha_staged}" &&
      "${archive_sha_before}" == "${archive_sha_after}" ]] ||
      fail "--kubectl-ate-archive changed while it was being staged"
    rm -f -- "${archive_anchor}"
    archive_anchor=""
    rmdir -- "${archive_stage_dir}"
    archive_stage_dir=""
  else
    release_json="${scratch_dir}/release.json"
    ref_json="${scratch_dir}/release-ref.json"
    tag_json="${scratch_dir}/release-tag.json"
    commit_json="${scratch_dir}/release-commit.json"
    checksums_file="${scratch_dir}/${kubectl_ate_checksums_name}"
    attestation_json="${scratch_dir}/release-attestation.json"

    github_api_to_file \
      "repos/pilprod/substrate/releases/tags/${kubectl_ate_release_tag}" "${release_json}"
    github_api_to_file \
      "repos/pilprod/substrate/git/ref/tags/${kubectl_ate_release_tag}" "${ref_json}"
    github_api_to_file \
      "repos/pilprod/substrate/git/tags/${kubectl_ate_release_tag_object}" "${tag_json}"
    github_api_to_file \
      "repos/pilprod/substrate/commits/${kubectl_ate_release_commit}" "${commit_json}"
    verify_release_asset_metadata \
      "${release_json}" "${archive_name}" "${expected_archive_sha256}" "${expected_archive_size}"
    verify_release_asset_metadata \
      "${release_json}" "${kubectl_ate_checksums_name}" \
      "${kubectl_ate_checksums_sha256}" "${kubectl_ate_checksums_size}"
    verify_release_source_identity "${ref_json}" "${tag_json}" "${commit_json}"

    download_github_release_asset "${archive_name}" "${staged_archive}"
    download_github_release_asset "${kubectl_ate_checksums_name}" "${checksums_file}"
    chmod 0600 "${staged_archive}" "${checksums_file}"
    [[ "$(sha256_file "${staged_archive}")" == "${expected_archive_sha256}" ]] ||
      fail "downloaded kubectl-ate archive digest does not match GitHub release metadata"
    [[ "$(sha256_file "${checksums_file}")" == "${kubectl_ate_checksums_sha256}" ]] ||
      fail "downloaded kubectl-ate checksums digest does not match GitHub release metadata"
    downloaded_archive_size="$(portable_stat "${staged_archive}" | awk '{print $3}')"
    downloaded_checksums_size="$(portable_stat "${checksums_file}" | awk '{print $3}')"
    [[ "${downloaded_archive_size}" == "${expected_archive_size}" ]] ||
      fail "downloaded kubectl-ate archive size does not match GitHub release metadata"
    [[ "${downloaded_checksums_size}" == "${kubectl_ate_checksums_size}" ]] ||
      fail "downloaded kubectl-ate checksums size does not match GitHub release metadata"
    awk -v digest="${expected_archive_sha256}" -v asset="${archive_name}" '
      $1 == digest && $2 == asset { matches++ }
      END { exit(matches == 1 ? 0 : 1) }
    ' "${checksums_file}" ||
      fail "published kubectl-ate checksums do not contain the exact selected archive"
    verify_release_attestation_if_available \
      "${staged_archive}" "${archive_name}" "${expected_archive_sha256}" "${attestation_json}"
  fi

  archive_members="${scratch_dir}/archive-members"
  if ! LC_ALL=C tar -tzf "${staged_archive}" > "${archive_members}" 2>/dev/null; then
    fail "pinned kubectl-ate archive is not a valid gzip-compressed tar archive"
  fi
  [[ "$(awk 'END { print NR }' "${archive_members}")" == "1" ]] &&
    grep -qx 'kubectl-ate' "${archive_members}" ||
    fail "pinned kubectl-ate archive must contain only the root kubectl-ate binary"
  if ! tar -xOzf "${staged_archive}" kubectl-ate > "${runtime_binary}"; then
    fail "could not extract kubectl-ate from the pinned release archive"
  fi
  chmod 0700 "${runtime_binary}"
  runtime_uid=""
  runtime_mode=""
  runtime_size=""
  if ! IFS=' ' read -r runtime_uid runtime_mode runtime_size < <(portable_stat "${runtime_binary}"); then
    fail "could not inspect the extracted kubectl-ate binary"
  fi
  [[ "${runtime_uid}" == "${current_uid}" && "${runtime_mode}" == "700" ]] ||
    fail "the extracted kubectl-ate binary must have exact owner-only ownership and mode"
  [[ "${runtime_size}" == "${expected_binary_size}" ]] ||
    fail "the extracted kubectl-ate binary size does not match the pinned release"
  [[ "$(sha256_file "${runtime_binary}")" == "${expected_binary_sha256}" ]] ||
    fail "the extracted kubectl-ate binary digest does not match the pinned release"
fi

kubectl config get-contexts "${kube_context}" --no-headers | grep -q '[^[:space:]]' ||
  fail "--context does not identify an available kubectl context"
kubectl --context="${kube_context}" --request-timeout=30s \
  get namespace "${namespace}" --output=name >/dev/null
live_cluster_dns_ip="$(
  kubectl --context="${kube_context}" --namespace=kube-system --request-timeout=30s \
    get service kube-dns --output='jsonpath={.spec.clusterIP}'
)"
[[ "${live_cluster_dns_ip}" == "${cluster_dns_ip}" ]] ||
  fail "--cluster-dns-ip does not match kube-system/kube-dns ClusterIP"
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  get serviceaccount "${service_account}" --output=name >/dev/null
kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
  get secret "${ca_secret}" \
  --output='go-template={{if index .data "server-ca.pem"}}present{{end}}{{"\n"}}' |
  grep -qx 'present' || fail "--ca-secret is missing server-ca.pem"
persistent_policy_contract=""
if ! persistent_policy_contract="$(
  kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
    get networkpolicy "${persistent_networkpolicy_name}" \
    --output='go-template={{index .spec.podSelector.matchLabels "app.kubernetes.io/name"}}|{{index .spec.podSelector.matchLabels "app.kubernetes.io/component"}}|{{index .spec.podSelector.matchLabels "app.kubernetes.io/part-of"}}|{{len .spec.podSelector.matchLabels}}|{{len .spec.podSelector.matchExpressions}}|{{range .spec.policyTypes}}{{.}},{{end}}|{{len .spec.ingress}}|{{len .spec.egress}}{{"\n"}}'
)"; then
  fail "persistent enrollment default-deny NetworkPolicy is missing"
fi
[[ "${persistent_policy_contract}" == "substrate-enrollment-admin|enrollment-admin|kagent-substrate-testbed|3|0|Ingress,Egress,|0|0" ||
  "${persistent_policy_contract}" == "substrate-enrollment-admin|enrollment-admin|kagent-substrate-testbed|3|0|Egress,Ingress,|0|0" ]] ||
  fail "persistent enrollment default-deny NetworkPolicy does not match the required fail-closed contract"

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
        - ipBlock:
            cidr: ${cluster_dns_ip}/32
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
# failure. The image mode starts issuance as part of Pod startup, so its
# no-automatic-retry fence begins before create. Native mode starts only a
# transfer sleeper and delays that fence until the explicit exec below.
pod_may_exist=1
if [[ "${kubectl_ate_mode}" == "image" ]]; then
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
else
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
  nodeSelector:
    kubernetes.io/os: linux
    kubernetes.io/arch: ${runtime_arch}
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
    - name: runtime
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
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
  containers:
    - name: transfer
      image: ${transfer_image}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -ceu
        - |
          umask 077
          mkdir -p /var/run/substrate-enrollment/private /var/run/substrate-runtime/bin
          chmod 0700 /var/run/substrate-enrollment/private /var/run/substrate-runtime/bin
          trap 'exit 0' TERM INT
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
          cpu: 10m
          memory: 64Mi
        limits:
          cpu: 250m
          memory: 256Mi
      volumeMounts:
        - name: handoff
          mountPath: /var/run/substrate-enrollment
        - name: runtime
          mountPath: /var/run/substrate-runtime
        - name: policy
          mountPath: /var/run/substrate-policy
          readOnly: true
        - name: substrate-token
          mountPath: /var/run/secrets/substrate
          readOnly: true
        - name: substrate-server-ca
          mountPath: /var/run/secrets/substrate-ca
          readOnly: true
EOF

  if ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout="${wait_timeout_seconds}s" \
    wait --for=condition=Ready "pod/${pod_name}" --timeout="${wait_timeout_seconds}s" >/dev/null; then
    fail "native kubectl-ate transfer Pod did not become ready"
  fi

  # Stream only the already-verified executable. kubectl cp is deliberately not
  # used because it requires tar in the Pod and creates a less explicit transfer
  # surface. The fixed remote shell receives no credential or caller input.
  if ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=120s \
    exec -i "pod/${pod_name}" -c transfer -- /bin/sh -ceu \
      'umask 077; mkdir -p /var/run/substrate-runtime/bin; chmod 0700 /var/run/substrate-runtime/bin; cat > /var/run/substrate-runtime/bin/kubectl-ate; chmod 0700 /var/run/substrate-runtime/bin/kubectl-ate; test -x /var/run/substrate-runtime/bin/kubectl-ate' \
      < "${runtime_binary}" >/dev/null; then
    fail "verified kubectl-ate binary transfer into the restricted Pod failed"
  fi

  remote_binary_digest_file="${scratch_dir}/remote-binary-digest"
  if ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=30s \
    exec "pod/${pod_name}" -c transfer -- sha256sum "${kubectl_ate_binary_path}" \
      > "${remote_binary_digest_file}"; then
    fail "could not verify the transferred kubectl-ate binary inside the restricted Pod"
  fi
  remote_binary_digest="$(awk 'NR == 1 { print $1 } END { if (NR != 1) exit 1 }' \
    "${remote_binary_digest_file}")" ||
    fail "the in-cluster kubectl-ate digest response was malformed"
  [[ "${remote_binary_digest}" == "${expected_binary_sha256}" ]] ||
    fail "the transferred in-cluster kubectl-ate binary digest does not match the pinned release"

  # The exec request may reach the Pod even if the local kubectl process reports
  # a transport error, so all failures from this point are issuance-ambiguous.
  issuance_may_have_happened=1
  if ! kubectl --context="${kube_context}" --namespace="${namespace}" --request-timeout=120s \
    exec "pod/${pod_name}" -c transfer -- "${kubectl_ate_binary_path}" \
      --endpoint "${api_endpoint}" \
      --token-file "${token_path}" \
      --server-ca-file "${server_ca_path}" \
      --server-name "${server_name}" \
      admin create external-provider-enrollment \
      --owner-atespace "${owner_atespace}" \
      --worker-namespace "${worker_namespace}" \
      --worker-pool "${worker_pool}" \
      --max-slots "${max_slots}" \
      --slot-policy "${policy_mount_path}" \
      --ttl "${ttl}" \
      --credential-file "${credential_path}" >/dev/null 2>&1; then
    fail "the native in-cluster enrollment command exited unsuccessfully; credential output was not read"
  fi
  deadline=$((SECONDS + wait_timeout_seconds))
fi

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
allowed_credential_size="$(LC_ALL=C tr -cd 'A-Za-z0-9_-' < "${local_partial}" | wc -c | awk '{print $1}')"
[[ "${allowed_credential_size}" =~ ^[0-9]+$ && "${allowed_credential_size}" == "${partial_size}" ]] ||
  fail "the transferred enrollment credential has invalid characters"

# A same-directory hard link atomically publishes a new name and cannot replace
# a destination created after the initial preflight check.
if ! ln "${local_partial}" "${output_file}"; then
  fail "could not atomically publish --output-file without overwriting a path"
fi
rm -f -- "${local_partial}"
local_partial=""

printf 'Substrate external-provider enrollment credential written to %s\n' "${output_file}"
