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
real_shasum_command="$(command -v shasum)"

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

native_fixture_dir="${private_dir}/native-fixture"
mkdir "${native_fixture_dir}"
chmod 0700 "${native_fixture_dir}"
printf '%s' 'fixture-static-kubectl-ate' > "${native_fixture_dir}/kubectl-ate"
chmod 0700 "${native_fixture_dir}/kubectl-ate"
native_archive="${private_dir}/kubectl-ate-v0.0.22-linux-amd64.tar.gz"
tar -czf "${native_archive}" -C "${native_fixture_dir}" kubectl-ate
chmod 0600 "${native_archive}"

release_json="${temporary_dir}/release.json"
ref_json="${temporary_dir}/ref.json"
tag_json="${temporary_dir}/tag.json"
commit_json="${temporary_dir}/commit.json"
attestation_json="${temporary_dir}/attestation.json"
cat > "${release_json}" <<'EOF'
{"id":379407334,"tag_name":"v0.0.22","target_commitish":"main","immutable":true,"draft":false,"prerelease":false,"author":{"login":"pilprod","id":51009687},"assets":[{"name":"kubectl-ate-v0.0.22-checksums.txt","state":"uploaded","size":422,"digest":"sha256:f03851b9fa61cf37b2dbf32b2069ee98685603f5b2f4f07e9d1df56f9888a038","browser_download_url":"https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-checksums.txt"},{"name":"kubectl-ate-v0.0.22-linux-amd64.tar.gz","state":"uploaded","size":14619282,"digest":"sha256:ea43473b1bc144236541d1e9213a375f23f0a1705254332eae5465d500ce7e15","browser_download_url":"https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-linux-amd64.tar.gz"},{"name":"kubectl-ate-v0.0.22-linux-arm64.tar.gz","state":"uploaded","size":12892846,"digest":"sha256:fa6b8356c2745761ebf24e4448960fcc4e067721bcadeec603bb11364f60f211","browser_download_url":"https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-linux-arm64.tar.gz"}]}
EOF
cat > "${ref_json}" <<'EOF'
{"ref":"refs/tags/v0.0.22","object":{"type":"tag","sha":"00a6a684cea3b3feea67461cf79347332ec759ef"}}
EOF
cat > "${tag_json}" <<'EOF'
{"sha":"00a6a684cea3b3feea67461cf79347332ec759ef","tag":"v0.0.22","object":{"type":"commit","sha":"e9ed68e587b56df2aa2a7f0267a744598c4d48b4"},"verification":{"verified":false,"reason":"unknown_key","signature":"signed","payload":"payload"}}
EOF
cat > "${commit_json}" <<'EOF'
{"sha":"e9ed68e587b56df2aa2a7f0267a744598c4d48b4","author":{"login":"pilprod","id":51009687},"committer":{"login":"web-flow"},"commit":{"verification":{"verified":true,"reason":"valid"}}}
EOF
cat > "${attestation_json}" <<'EOF'
{"verificationResult":{"signature":{"certificate":{"subjectAlternativeName":"https://dotcom.releases.github.com"}},"verifiedTimestamps":[{"type":"TimestampAuthority"}],"statement":{"predicateType":"https://in-toto.io/attestation/release/v0.2","subject":[{"uri":"pkg:github/pilprod/substrate@v0.0.22","digest":{"sha1":"00a6a684cea3b3feea67461cf79347332ec759ef"}},{"name":"kubectl-ate-v0.0.22-linux-amd64.tar.gz","digest":{"sha256":"ea43473b1bc144236541d1e9213a375f23f0a1705254332eae5465d500ce7e15"}}],"predicate":{"repository":"pilprod/substrate","repositoryId":"1351629720","ownerId":"51009687","databaseId":"379407334","tag":"v0.0.22"}}}}
EOF

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
if [[ "${all_args}" == *' exec -i pod/'* && "${all_args}" == *'/bin/sh -ceu'* &&
  "${all_args}" == *'/var/run/substrate-runtime/bin/kubectl-ate'* ]]; then
  [[ "${FAKE_NATIVE_UPLOAD_FAIL:-0}" != 1 ]] || exit 77
  while IFS= read -r -n 8192 chunk; do :; done
  exit 0
fi
if [[ "${all_args}" == *' exec pod/'* && "${all_args}" == *' -- sha256sum '* &&
  "${all_args}" == *'/var/run/substrate-runtime/bin/kubectl-ate'* ]]; then
  [[ "${FAKE_REMOTE_DIGEST_FAIL:-0}" != 1 ]] || exit 79
  if [[ "${FAKE_RUNTIME_ARCH:-amd64}" == arm64 ]]; then
    default_remote_sha='58276a98cad397865ab4eae838371a6353b1b549b37a62b70443428de5158dce'
  else
    default_remote_sha='bcefdf7b564233272c299a1182ca905d092426a2fa4b516e7adfe9ed8d9ebc3a'
  fi
  printf '%s  %s\n' "${FAKE_REMOTE_BINARY_SHA256:-${default_remote_sha}}" \
    '/var/run/substrate-runtime/bin/kubectl-ate'
  exit 0
fi
if [[ "${all_args}" == *' exec pod/'* &&
  "${all_args}" == *'/var/run/substrate-runtime/bin/kubectl-ate'* &&
  "${all_args}" == *' external-provider-enrollment '* ]]; then
  [[ "${FAKE_NATIVE_EXEC_FAIL:-0}" != 1 ]] || exit 78
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
  if [[ "${FAKE_NATIVE_STAT:-0}" == 1 && "${format}" == '%u %a %s' ]]; then
    owner="$(${REAL_STAT:?} -f '%u' "${path}" 2>/dev/null || ${REAL_STAT} -c '%u' "${path}")"
    mode="$(${REAL_STAT} -f '%Lp' "${path}" 2>/dev/null || ${REAL_STAT} -c '%a' "${path}")"
    case "${path}" in
      *'/.yourown-chat-kubectl-ate-stage.'*'/source')
        if [[ "${FAKE_RUNTIME_ARCH:-amd64}" == arm64 ]]; then
          default_size=12892846
        else
          default_size=14619282
        fi
        printf '%s %s %s\n' "${owner}" "${mode}" "${FAKE_NATIVE_ARCHIVE_SIZE:-${default_size}}"
        exit 0
        ;;
      *'/kubectl-ate-v0.0.22-linux-amd64.tar.gz')
        printf '%s %s %s\n' "${owner}" "${mode}" "${FAKE_NATIVE_ARCHIVE_SIZE:-14619282}"
        exit 0
        ;;
      *'/kubectl-ate-v0.0.22-linux-arm64.tar.gz')
        printf '%s %s %s\n' "${owner}" "${mode}" "${FAKE_NATIVE_ARCHIVE_SIZE:-12892846}"
        exit 0
        ;;
      *'/kubectl-ate-v0.0.22-checksums.txt')
        printf '%s %s %s\n' "${owner}" "${mode}" '422'
        exit 0
        ;;
      *'/yourown-chat-enrollment.'*'/kubectl-ate')
        if [[ "${FAKE_RUNTIME_ARCH:-amd64}" == arm64 ]]; then
          binary_size=48627874
        else
          binary_size=51855522
        fi
        printf '%s %s %s\n' "${owner}" "${mode}" "${binary_size}"
        exit 0
        ;;
    esac
  fi
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

cat > "${fake_bin}/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

path="$1"
case "${path}" in
  *'/.yourown-chat-kubectl-ate-stage.'*'/source')
    if [[ "${FAKE_RUNTIME_ARCH:-amd64}" == arm64 ]]; then
      default_sha='fa6b8356c2745761ebf24e4448960fcc4e067721bcadeec603bb11364f60f211'
    else
      default_sha='ea43473b1bc144236541d1e9213a375f23f0a1705254332eae5465d500ce7e15'
    fi
    printf '%s  %s\n' "${FAKE_NATIVE_ARCHIVE_SHA256:-${default_sha}}" "${path}"
    ;;
  *'/kubectl-ate-v0.0.22-linux-amd64.tar.gz')
    printf '%s  %s\n' "${FAKE_NATIVE_ARCHIVE_SHA256:-ea43473b1bc144236541d1e9213a375f23f0a1705254332eae5465d500ce7e15}" "${path}"
    ;;
  *'/kubectl-ate-v0.0.22-linux-arm64.tar.gz')
    printf '%s  %s\n' "${FAKE_NATIVE_ARCHIVE_SHA256:-fa6b8356c2745761ebf24e4448960fcc4e067721bcadeec603bb11364f60f211}" "${path}"
    ;;
  *'/kubectl-ate-v0.0.22-checksums.txt')
    printf '%s  %s\n' 'f03851b9fa61cf37b2dbf32b2069ee98685603f5b2f4f07e9d1df56f9888a038' "${path}"
    ;;
  *'/yourown-chat-enrollment.'*'/kubectl-ate')
    if [[ "${FAKE_RUNTIME_ARCH:-amd64}" == arm64 ]]; then
      default_binary_sha='58276a98cad397865ab4eae838371a6353b1b549b37a62b70443428de5158dce'
    else
      default_binary_sha='bcefdf7b564233272c299a1182ca905d092426a2fa4b516e7adfe9ed8d9ebc3a'
    fi
    printf '%s  %s\n' "${FAKE_NATIVE_BINARY_SHA256:-${default_binary_sha}}" "${path}"
    ;;
  *)
    exec "${REAL_SHASUM:?}" -a 256 "${path}"
    ;;
esac
EOF
chmod 0755 "${fake_bin}/sha256sum"

cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

{
  printf 'curl'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FAKE_KUBECTL_LOG_DIR:?}/curl.log"
[[ "${FAKE_CURL_FAIL:-0}" != 1 ]] || exit 22
destination=""
previous=""
for argument in "$@"; do
  if [[ "${previous}" == '--output' ]]; then
    destination="${argument}"
    previous=""
    continue
  fi
  previous="${argument}"
done
[[ -n "${destination}" ]] || exit 94
url="${!#}"
case "${url}" in
  'https://api.github.com/repos/pilprod/substrate/releases/tags/v0.0.22')
    cp "${FAKE_RELEASE_JSON:?}" "${destination}"
    ;;
  'https://api.github.com/repos/pilprod/substrate/git/ref/tags/v0.0.22')
    cp "${FAKE_REF_JSON:?}" "${destination}"
    ;;
  'https://api.github.com/repos/pilprod/substrate/git/tags/00a6a684cea3b3feea67461cf79347332ec759ef')
    cp "${FAKE_TAG_JSON:?}" "${destination}"
    ;;
  'https://api.github.com/repos/pilprod/substrate/commits/e9ed68e587b56df2aa2a7f0267a744598c4d48b4')
    cp "${FAKE_COMMIT_JSON:?}" "${destination}"
    ;;
  'https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-linux-amd64.tar.gz')
    cp "${FAKE_NATIVE_ARCHIVE:?}" "${destination}"
    ;;
  'https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-linux-arm64.tar.gz')
    cp "${FAKE_NATIVE_ARCHIVE:?}" "${destination}"
    ;;
  'https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-checksums.txt')
    if [[ "${FAKE_CHECKSUMS_MISMATCH:-0}" == 1 ]]; then
      printf '%s  %s\n' 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
        "kubectl-ate-v0.0.22-linux-${FAKE_RUNTIME_ARCH:-amd64}.tar.gz" > "${destination}"
    else
      if [[ "${FAKE_RUNTIME_ARCH:-amd64}" == arm64 ]]; then
        checksum='fa6b8356c2745761ebf24e4448960fcc4e067721bcadeec603bb11364f60f211'
      else
        checksum='ea43473b1bc144236541d1e9213a375f23f0a1705254332eae5465d500ce7e15'
      fi
      printf '%s  %s\n' "${checksum}" \
        "kubectl-ate-v0.0.22-linux-${FAKE_RUNTIME_ARCH:-amd64}.tar.gz" > "${destination}"
    fi
    ;;
  *) exit 95 ;;
esac
EOF
chmod 0755 "${fake_bin}/curl"

cat > "${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

{
  printf 'gh'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FAKE_KUBECTL_LOG_DIR:?}/gh.log"
case "$1 $2" in
  'auth status')
    [[ "${FAKE_GH_AUTHENTICATED:-0}" == 1 ]]
    exit
    ;;
  'api --hostname')
    endpoint="${!#}"
    case "${endpoint}" in
      'repos/pilprod/substrate/releases/tags/v0.0.22') cat "${FAKE_RELEASE_JSON:?}" ;;
      'repos/pilprod/substrate/git/ref/tags/v0.0.22') cat "${FAKE_REF_JSON:?}" ;;
      'repos/pilprod/substrate/git/tags/00a6a684cea3b3feea67461cf79347332ec759ef') cat "${FAKE_TAG_JSON:?}" ;;
      'repos/pilprod/substrate/commits/e9ed68e587b56df2aa2a7f0267a744598c4d48b4') cat "${FAKE_COMMIT_JSON:?}" ;;
      *) exit 96 ;;
    esac
    ;;
  'release verify-asset')
    if [[ "$*" == *' --help'* ]]; then
      exit 0
    fi
    [[ "${FAKE_ATTESTATION_FAIL:-0}" != 1 ]] || exit 97
    cat "${FAKE_ATTESTATION_JSON:?}"
    ;;
  *) exit 98 ;;
esac
EOF
chmod 0755 "${fake_bin}/gh"

digest_a="sha256:$(repeat_hex a)"
digest_b="sha256:$(repeat_hex b)"
valid_kubectl_image="ghcr.io/pilprod/substrate/kubectl-ate@${digest_a}"
valid_transfer_image="registry.k8s.io/busybox@${digest_b}"

invoke_with_source() {
  local destination="$1"
  shift

  PATH="${fake_bin}:${PATH}" \
  REAL_STAT="${real_stat_command}" \
  REAL_SHASUM="${real_shasum_command}" \
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
  FAKE_NATIVE_STAT="${FAKE_NATIVE_STAT:-0}" \
  FAKE_RUNTIME_ARCH="${FAKE_RUNTIME_ARCH:-${RUNTIME_ARCH:-amd64}}" \
  FAKE_NATIVE_ARCHIVE_SIZE="${FAKE_NATIVE_ARCHIVE_SIZE:-}" \
  FAKE_NATIVE_ARCHIVE_SHA256="${FAKE_NATIVE_ARCHIVE_SHA256:-}" \
  FAKE_NATIVE_BINARY_SHA256="${FAKE_NATIVE_BINARY_SHA256:-}" \
  FAKE_NATIVE_UPLOAD_FAIL="${FAKE_NATIVE_UPLOAD_FAIL:-0}" \
  FAKE_REMOTE_DIGEST_FAIL="${FAKE_REMOTE_DIGEST_FAIL:-0}" \
  FAKE_REMOTE_BINARY_SHA256="${FAKE_REMOTE_BINARY_SHA256:-}" \
  FAKE_NATIVE_EXEC_FAIL="${FAKE_NATIVE_EXEC_FAIL:-0}" \
  FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
  FAKE_CHECKSUMS_MISMATCH="${FAKE_CHECKSUMS_MISMATCH:-0}" \
  FAKE_GH_AUTHENTICATED="${FAKE_GH_AUTHENTICATED:-0}" \
  FAKE_ATTESTATION_FAIL="${FAKE_ATTESTATION_FAIL:-0}" \
  FAKE_RELEASE_JSON="${FAKE_RELEASE_JSON:-${release_json}}" \
  FAKE_REF_JSON="${FAKE_REF_JSON:-${ref_json}}" \
  FAKE_TAG_JSON="${FAKE_TAG_JSON:-${tag_json}}" \
  FAKE_COMMIT_JSON="${FAKE_COMMIT_JSON:-${commit_json}}" \
  FAKE_ATTESTATION_JSON="${FAKE_ATTESTATION_JSON:-${attestation_json}}" \
  FAKE_NATIVE_ARCHIVE="${FAKE_NATIVE_ARCHIVE:-${native_archive}}" \
    "${subject}" \
    "$@" \
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

invoke_subject() {
  local destination="$1"

  invoke_with_source "${destination}" \
    --kubectl-ate-image "${KUBECTL_IMAGE:-${valid_kubectl_image}}"
}

invoke_native_release() {
  local destination="$1"

  FAKE_NATIVE_STAT=1 invoke_with_source "${destination}" \
    --kubectl-ate-release "${KUBECTL_ATE_RELEASE:-v0.0.22}" \
    --runtime-arch "${RUNTIME_ARCH:-amd64}"
}

invoke_native_archive() {
  local destination="$1"

  FAKE_NATIVE_STAT=1 invoke_with_source "${destination}" \
    --kubectl-ate-archive "${KUBECTL_ATE_ARCHIVE:-${native_archive}}" \
    --runtime-arch "${RUNTIME_ARCH:-amd64}"
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

expect_native_release_failure() {
  local label="$1"
  local expected="$2"
  local destination="$3"
  local stdout_file="${temporary_dir}/${label}.stdout"
  local stderr_file="${temporary_dir}/${label}.stderr"

  if invoke_native_release "${destination}" > "${stdout_file}" 2> "${stderr_file}"; then
    fail "${label} unexpectedly succeeded"
  fi
  [[ ! -e "${destination}" ]] || fail "${label} published an output file"
  require_literal "${stderr_file}" "${expected}"
}

expect_native_archive_failure() {
  local label="$1"
  local expected="$2"
  local destination="$3"
  local stdout_file="${temporary_dir}/${label}.stdout"
  local stderr_file="${temporary_dir}/${label}.stderr"

  if invoke_native_archive "${destination}" > "${stdout_file}" 2> "${stderr_file}"; then
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

native_release_log="${temporary_dir}/native-release-log"
mkdir -p "${native_release_log}"
native_release_output="${private_dir}/native-release-enrollment-token"
FAKE_KUBECTL_LOG_DIR="${native_release_log}" FAKE_GH_AUTHENTICATED=0 \
  invoke_native_release "${native_release_output}" \
  > "${temporary_dir}/native-release.stdout" 2> "${temporary_dir}/native-release.stderr"
[[ -f "${native_release_output}" ]] || fail "native release invocation did not publish the credential"
[[ "$(PATH="${fake_bin}:${PATH}" REAL_STAT="${real_stat_command}" file_mode "${native_release_output}")" == 600 ]] ||
  fail "native release credential mode is not 0600"
[[ "$(<"${native_release_output}")" == 'enrollment_A1-b2' ]] ||
  fail "native release credential bytes changed"
native_pod_manifest="${native_release_log}/pod.yaml"
require_literal "${native_pod_manifest}" '    kubernetes.io/os: linux'
require_literal "${native_pod_manifest}" '    kubernetes.io/arch: amd64'
require_literal "${native_pod_manifest}" '    - name: runtime'
require_literal "${native_pod_manifest}" '        sizeLimit: 64Mi'
require_literal "${native_pod_manifest}" "image: ${valid_transfer_image}"
[[ "$(grep -Fc -- "image: ${valid_transfer_image}" "${native_pod_manifest}")" -eq 1 ]] ||
  fail "native Pod must contain exactly one pinned transfer container"
forbid_pattern "${native_pod_manifest}" 'name: issue-enrollment|kubectl-ate@sha256|^kind: Secret$'
forbid_pattern "${native_pod_manifest}" 'enrollment_A1-b2'
require_literal "${native_release_log}/calls.log" '<exec> <-i> <pod/substrate-enrollment-'
require_literal "${native_release_log}/calls.log" '<--> <sha256sum> </var/run/substrate-runtime/bin/kubectl-ate>'
require_literal "${native_release_log}/calls.log" '</var/run/substrate-runtime/bin/kubectl-ate>'
require_literal "${native_release_log}/calls.log" '<admin> <create> <external-provider-enrollment>'
require_literal "${native_release_log}/calls.log" '<--credential-file> </var/run/substrate-enrollment/private/enrollment-credential>'
forbid_pattern "${native_release_log}/calls.log" 'enrollment_A1-b2|port-forward'
require_literal "${native_release_log}/curl.log" '<https://api.github.com/repos/pilprod/substrate/releases/tags/v0.0.22>'
require_literal "${native_release_log}/curl.log" '<https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-linux-amd64.tar.gz>'
require_literal "${native_release_log}/gh.log" '<auth> <status> <--hostname> <github.com>'
[[ "$(grep -Fc '<auth> <status> <--hostname> <github.com>' "${native_release_log}/gh.log")" -eq 1 ]] ||
  fail "unauthenticated release path must probe gh auth at most once"
forbid_pattern "${native_release_log}/gh.log" '<login>|<refresh>|<release> <verify-asset>'
forbid_pattern "${temporary_dir}/native-release.stdout" 'enrollment_A1-b2'
forbid_pattern "${temporary_dir}/native-release.stderr" 'enrollment_A1-b2'

native_arm64_log="${temporary_dir}/native-arm64-log"
mkdir -p "${native_arm64_log}"
FAKE_KUBECTL_LOG_DIR="${native_arm64_log}" FAKE_GH_AUTHENTICATED=0 RUNTIME_ARCH=arm64 \
  invoke_native_release "${private_dir}/native-arm64-token" \
  > "${temporary_dir}/native-arm64.stdout" 2> "${temporary_dir}/native-arm64.stderr"
require_literal "${native_arm64_log}/pod.yaml" '    kubernetes.io/arch: arm64'
require_literal "${native_arm64_log}/curl.log" '<https://github.com/pilprod/substrate/releases/download/v0.0.22/kubectl-ate-v0.0.22-linux-arm64.tar.gz>'

attested_log="${temporary_dir}/attested-release-log"
mkdir -p "${attested_log}"
FAKE_KUBECTL_LOG_DIR="${attested_log}" FAKE_GH_AUTHENTICATED=1 \
  invoke_native_release "${private_dir}/attested-release-token" \
  > "${temporary_dir}/attested-release.stdout" 2> "${temporary_dir}/attested-release.stderr"
require_literal "${attested_log}/gh.log" '<release> <verify-asset> <v0.0.22>'
require_literal "${attested_log}/gh.log" '<api> <--hostname> <github.com>'
forbid_pattern "${attested_log}/gh.log" '<login>|<refresh>'

native_archive_log="${temporary_dir}/native-archive-log"
mkdir -p "${native_archive_log}"
FAKE_KUBECTL_LOG_DIR="${native_archive_log}" \
  invoke_native_archive "${private_dir}/native-archive-token" \
  > "${temporary_dir}/native-archive.stdout" 2> "${temporary_dir}/native-archive.stderr"
[[ ! -e "${native_archive_log}/curl.log" ]] || fail "owner-supplied archive unexpectedly used curl"
[[ ! -e "${native_archive_log}/gh.log" ]] || fail "owner-supplied archive unexpectedly used gh"
require_literal "${native_archive_log}/calls.log" '<exec> <-i> <pod/substrate-enrollment-'

require_literal "${subject}" 'readonly kubectl_ate_release_tag="v0.0.22"'
require_literal "${subject}" 'readonly kubectl_ate_release_tag_object="00a6a684cea3b3feea67461cf79347332ec759ef"'
require_literal "${subject}" 'readonly kubectl_ate_release_commit="e9ed68e587b56df2aa2a7f0267a744598c4d48b4"'
require_literal "${subject}" 'readonly kubectl_ate_linux_amd64_sha256="ea43473b1bc144236541d1e9213a375f23f0a1705254332eae5465d500ce7e15"'
require_literal "${subject}" 'readonly kubectl_ate_linux_arm64_sha256="fa6b8356c2745761ebf24e4448960fcc4e067721bcadeec603bb11364f60f211"'
forbid_pattern "${subject}" 'gh auth (login|refresh)|^[[:space:]]*kubectl[[:space:]]+cp'

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

native_validation_log="${temporary_dir}/native-validation-log"
mkdir -p "${native_validation_log}"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" KUBECTL_ATE_RELEASE=v0.0.23 \
  expect_native_release_failure wrong-native-release '--kubectl-ate-release must be exactly v0.0.22' \
    "${private_dir}/wrong-native-release"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" RUNTIME_ARCH=darwin-arm64 \
  expect_native_release_failure wrong-native-arch '--runtime-arch must be exactly amd64 or arm64' \
    "${private_dir}/wrong-native-arch"

if FAKE_KUBECTL_LOG_DIR="${native_validation_log}" invoke_with_source \
  "${private_dir}/multiple-native-source" \
  --kubectl-ate-release v0.0.22 --runtime-arch amd64 \
  --kubectl-ate-image "${valid_kubectl_image}" \
  > "${temporary_dir}/multiple-native-source.stdout" \
  2> "${temporary_dir}/multiple-native-source.stderr"; then
  fail "multiple kubectl-ate sources unexpectedly succeeded"
fi
require_literal "${temporary_dir}/multiple-native-source.stderr" 'exactly one of --kubectl-ate-release'

if FAKE_KUBECTL_LOG_DIR="${native_validation_log}" invoke_with_source \
  "${private_dir}/missing-native-source" \
  > "${temporary_dir}/missing-native-source.stdout" \
  2> "${temporary_dir}/missing-native-source.stderr"; then
  fail "missing kubectl-ate source unexpectedly succeeded"
fi
require_literal "${temporary_dir}/missing-native-source.stderr" 'exactly one of --kubectl-ate-release'

bad_release_json="${temporary_dir}/bad-release.json"
sed 's/"immutable":true/"immutable":false/' "${release_json}" > "${bad_release_json}"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" FAKE_RELEASE_JSON="${bad_release_json}" \
  expect_native_release_failure mutable-release-metadata 'GitHub release metadata does not match pinned asset' \
    "${private_dir}/mutable-release-metadata"

bad_commit_json="${temporary_dir}/bad-commit.json"
sed 's/"verified":true/"verified":false/' "${commit_json}" > "${bad_commit_json}"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" FAKE_COMMIT_JSON="${bad_commit_json}" \
  expect_native_release_failure unverified-release-source 'source commit is not the pinned GitHub-verified commit' \
    "${private_dir}/unverified-release-source"

FAKE_KUBECTL_LOG_DIR="${native_validation_log}" FAKE_CURL_FAIL=1 \
  expect_native_release_failure release-download-failure 'could not read pinned Substrate release metadata' \
    "${private_dir}/release-download-failure"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" FAKE_CHECKSUMS_MISMATCH=1 \
  expect_native_release_failure release-checksum-mismatch 'published kubectl-ate checksums do not contain' \
    "${private_dir}/release-checksum-mismatch"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" FAKE_GH_AUTHENTICATED=1 FAKE_ATTESTATION_FAIL=1 \
  expect_native_release_failure release-attestation-failure 'signed immutable-release attestation did not verify' \
    "${private_dir}/release-attestation-failure"

FAKE_KUBECTL_LOG_DIR="${native_validation_log}" FAKE_NATIVE_ARCHIVE_SHA256="$(repeat_hex f)" \
  expect_native_archive_failure native-archive-wrong-digest '--kubectl-ate-archive digest does not match' \
    "${private_dir}/native-archive-wrong-digest"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" FAKE_NATIVE_ARCHIVE_SIZE=1 \
  expect_native_archive_failure native-archive-wrong-size '--kubectl-ate-archive size does not match' \
    "${private_dir}/native-archive-wrong-size"

chmod 0644 "${native_archive}"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" \
  expect_native_archive_failure native-archive-open-mode '--kubectl-ate-archive mode must be exactly 0400 or 0600' \
    "${private_dir}/native-archive-open-mode"
chmod 0600 "${native_archive}"

native_archive_link="${private_dir}/native-archive-link.tar.gz"
ln -s "${native_archive}" "${native_archive_link}"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" KUBECTL_ATE_ARCHIVE="${native_archive_link}" \
  expect_native_archive_failure native-archive-symlink '--kubectl-ate-archive must be a regular file, not a symlink' \
    "${private_dir}/native-archive-symlink"

bad_native_parent="${private_dir}/bad-native"
mkdir "${bad_native_parent}"
chmod 0700 "${bad_native_parent}"
printf '%s' 'extra' > "${bad_native_parent}/extra"
cp "${native_archive}" "${bad_native_parent}/kubectl-ate-v0.0.22-linux-amd64.tar.gz"
tar -czf "${bad_native_parent}/kubectl-ate-v0.0.22-linux-amd64.tar.gz" \
  -C "${native_fixture_dir}" kubectl-ate -C "${bad_native_parent}" extra
chmod 0600 "${bad_native_parent}/kubectl-ate-v0.0.22-linux-amd64.tar.gz"
FAKE_KUBECTL_LOG_DIR="${native_validation_log}" \
KUBECTL_ATE_ARCHIVE="${bad_native_parent}/kubectl-ate-v0.0.22-linux-amd64.tar.gz" \
  expect_native_archive_failure native-archive-extra-entry 'must contain only the root kubectl-ate binary' \
    "${private_dir}/native-archive-extra-entry"

[[ ! -s "${native_validation_log}/calls.log" ]] ||
  fail "native source validation adversaries reached kubectl"

native_upload_failure_log="${temporary_dir}/native-upload-failure-log"
mkdir -p "${native_upload_failure_log}"
FAKE_KUBECTL_LOG_DIR="${native_upload_failure_log}" FAKE_NATIVE_UPLOAD_FAIL=1 \
  expect_native_release_failure native-upload-failure 'binary transfer into the restricted Pod failed' \
    "${private_dir}/native-upload-failure"
forbid_pattern "${temporary_dir}/native-upload-failure.stderr" 'DO NOT RETRY automatically'
require_literal "${native_upload_failure_log}/calls.log" 'delete> <pod/substrate-enrollment-'

native_exec_failure_log="${temporary_dir}/native-exec-failure-log"
mkdir -p "${native_exec_failure_log}"
FAKE_KUBECTL_LOG_DIR="${native_exec_failure_log}" FAKE_NATIVE_EXEC_FAIL=1 \
  expect_native_release_failure native-exec-failure 'native in-cluster enrollment command exited unsuccessfully' \
    "${private_dir}/native-exec-failure"
require_literal "${temporary_dir}/native-exec-failure.stderr" 'DO NOT RETRY automatically; operator review is required'
forbid_pattern "${native_exec_failure_log}/calls.log" 'enrollment_A1-b2'

native_digest_failure_log="${temporary_dir}/native-digest-failure-log"
mkdir -p "${native_digest_failure_log}"
FAKE_KUBECTL_LOG_DIR="${native_digest_failure_log}" \
FAKE_REMOTE_BINARY_SHA256="$(repeat_hex f)" \
  expect_native_release_failure native-remote-digest-failure \
    'transferred in-cluster kubectl-ate binary digest does not match' \
    "${private_dir}/native-remote-digest-failure"
forbid_pattern "${temporary_dir}/native-remote-digest-failure.stderr" 'DO NOT RETRY automatically'
forbid_pattern "${native_digest_failure_log}/calls.log" '<admin> <create> <external-provider-enrollment>'

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
