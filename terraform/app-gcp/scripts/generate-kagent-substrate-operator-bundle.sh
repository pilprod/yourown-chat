#!/usr/bin/env bash
set -euo pipefail

umask 077

readonly default_ca_validity_days=3650
readonly default_leaf_validity_days=365
readonly minimum_ca_validity_days=365
readonly minimum_leaf_validity_days=30
readonly maximum_ca_validity_days=7300
readonly maximum_leaf_validity_days=825

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly bootstrap_script="${script_dir}/bootstrap-kagent-substrate-secrets.sh"

temp_dir=""
output=""
published=0

usage() {
  cat <<'USAGE'
Usage:
  generate-kagent-substrate-operator-bundle.sh \
    --project PROJECT \
    --output /absolute/secure/operator-bundle.json \
    [--ca-validity-days DAYS] \
    [--leaf-validity-days DAYS]

Generate a fresh, fixed-contract kagent/Substrate native Secret operator bundle.
Every key is newly generated as ECDSA P-256. The default CA lifetime is 3650
days and the default leaf lifetime is 365 days.

The output parent must already exist, be a real directory owned by the current
user with mode 0700, contain no symlink component, and live outside every Git
worktree or Git metadata directory. The output path must be absolute and must
not already exist. The resulting bundle is mode 0600 and contains unencrypted
private key material encoded as canonical base64.
USAGE
}

fail() {
  printf 'kagent/Substrate operator bundle generation failed: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

portable_mode() {
  local value=""
  value="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  if [[ ! "${value}" =~ ^[0-7]{3,4}$ ]]; then
    value="$(stat -c '%a' "$1" 2>/dev/null || true)"
  fi
  [[ "${value}" =~ ^[0-7]{3,4}$ ]] || fail "cannot determine filesystem permissions"
  printf '%s\n' "${value}"
}

portable_owner() {
  local value=""
  value="$(stat -f '%u' "$1" 2>/dev/null || true)"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    value="$(stat -c '%u' "$1" 2>/dev/null || true)"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "cannot determine filesystem owner"
  printf '%s\n' "${value}"
}

portable_link_count() {
  local value=""
  value="$(stat -f '%l' "$1" 2>/dev/null || true)"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    value="$(stat -c '%h' "$1" 2>/dev/null || true)"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "cannot determine filesystem link count"
  printf '%s\n' "${value}"
}

validate_output_parent_snapshot() {
  local parent="$1"
  local expected_identity="$2"
  python3 -I - "${parent}" "${expected_identity}" "$(id -u)" <<'PY'
import os
import stat
import sys

parent, expected_identity, expected_uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
metadata = os.lstat(parent)
if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
    raise SystemExit(1)
if os.path.realpath(parent) != parent:
    raise SystemExit(1)
if metadata.st_uid != expected_uid or stat.S_IMODE(metadata.st_mode) != 0o700:
    raise SystemExit(1)
if f"{metadata.st_dev}:{metadata.st_ino}" != expected_identity:
    raise SystemExit(1)
flags = os.O_RDONLY
flags |= getattr(os, "O_DIRECTORY", 0)
flags |= getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(parent, flags)
try:
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
        raise SystemExit(1)
    if opened.st_uid != expected_uid or stat.S_IMODE(opened.st_mode) != 0o700:
        raise SystemExit(1)
finally:
    os.close(descriptor)
PY
}

validate_outside_git() {
  local parent="$1"
  local inside_worktree=""
  local inside_git_dir=""
  inside_worktree="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
    git -C "${parent}" rev-parse --is-inside-work-tree 2>/dev/null || true)"
  inside_git_dir="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
    git -C "${parent}" rev-parse --is-inside-git-dir 2>/dev/null || true)"
  [[ "${inside_worktree}" != "true" && "${inside_git_dir}" != "true" ]]
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if (( status != 0 && published == 1 )) && [[ -n "${output}" && -f "${output}" && ! -L "${output}" ]]; then
    rm -f -- "${output}" 2>/dev/null || true
  fi
  if [[ -n "${temp_dir}" && -d "${temp_dir}" ]]; then
    find "${temp_dir}" -type f -exec chmod 0600 -- {} + 2>/dev/null || true
    find "${temp_dir}" -type f -exec rm -f -- {} +
    find "${temp_dir}" -depth -type d -exec rmdir -- {} + 2>/dev/null || true
  fi
  exit "${status}"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

openssl_step() {
  local label="$1"
  shift
  env -u OPENSSL_CONF -u OPENSSL_MODULES -u OPENSSL_ENGINES \
    OPENSSL_CONF=/dev/null openssl "$@" >/dev/null 2>&1 || \
    fail "OpenSSL failed while generating ${label}"
}

random_serial() {
  local value=""
  value="$(env -u OPENSSL_CONF -u OPENSSL_MODULES -u OPENSSL_ENGINES \
    OPENSSL_CONF=/dev/null openssl rand -hex 16 2>/dev/null)" || \
    fail "OpenSSL failed while generating a certificate serial"
  [[ "${value}" =~ ^[0-9a-f]{32}$ ]] || fail "OpenSSL returned an invalid certificate serial"
  printf '%s\n' "${value}"
}

make_ca() {
  local prefix="$1"
  local common_name="$2"
  local serial=""

  serial="$(random_serial)"
  openssl_step "${prefix} private key" genpkey \
    -algorithm EC \
    -pkeyopt ec_paramgen_curve:P-256 \
    -out "${temp_dir}/${prefix}.key.pem"
  openssl_step "${prefix} root certificate" req \
    -new \
    -x509 \
    -key "${temp_dir}/${prefix}.key.pem" \
    -sha256 \
    -days "${ca_validity_days}" \
    -set_serial "0x${serial}" \
    -subj "/CN=${common_name}" \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -addext 'subjectKeyIdentifier=hash' \
    -addext 'authorityKeyIdentifier=keyid:always' \
    -out "${temp_dir}/${prefix}.cert.pem"
}

make_leaf() {
  local prefix="$1"
  local common_name="$2"
  local ca_prefix="$3"
  local extended_key_usage="$4"
  local subject_alt_name="$5"
  local serial=""
  local extension_file="${temp_dir}/${prefix}.extensions.cnf"

  serial="$(random_serial)"
  printf '%s\n' \
    '[leaf]' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    "extendedKeyUsage=${extended_key_usage}" \
    "subjectAltName=${subject_alt_name}" \
    'subjectKeyIdentifier=hash' \
    'authorityKeyIdentifier=keyid,issuer' \
    > "${extension_file}"
  chmod 0600 "${extension_file}"

  openssl_step "${prefix} private key" genpkey \
    -algorithm EC \
    -pkeyopt ec_paramgen_curve:P-256 \
    -out "${temp_dir}/${prefix}.key.pem"
  openssl_step "${prefix} certificate request" req \
    -new \
    -key "${temp_dir}/${prefix}.key.pem" \
    -sha256 \
    -subj "/CN=${common_name}" \
    -out "${temp_dir}/${prefix}.csr.pem"
  openssl_step "${prefix} leaf certificate" x509 \
    -req \
    -in "${temp_dir}/${prefix}.csr.pem" \
    -CA "${temp_dir}/${ca_prefix}.cert.pem" \
    -CAkey "${temp_dir}/${ca_prefix}.key.pem" \
    -set_serial "0x${serial}" \
    -sha256 \
    -days "${leaf_validity_days}" \
    -extfile "${extension_file}" \
    -extensions leaf \
    -out "${temp_dir}/${prefix}.cert.pem"

  cp "${temp_dir}/${prefix}.key.pem" "${temp_dir}/${prefix}.bundle.pem"
  env -u OPENSSL_CONF -u OPENSSL_MODULES -u OPENSSL_ENGINES \
    OPENSSL_CONF=/dev/null openssl x509 \
    -in "${temp_dir}/${prefix}.cert.pem" \
    -outform PEM >> "${temp_dir}/${prefix}.bundle.pem" 2>/dev/null || \
    fail "OpenSSL failed while assembling ${prefix} credential bundle"
  chmod 0600 "${temp_dir}/${prefix}.bundle.pem"
}

project=""
requested_output=""
ca_validity_days="${default_ca_validity_days}"
leaf_validity_days="${default_leaf_validity_days}"
project_seen=0
output_seen=0
ca_days_seen=0
leaf_days_seen=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || fail "--project requires a value"
      (( project_seen == 0 )) || fail "--project may be specified only once"
      project="$2"
      project_seen=1
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a value"
      (( output_seen == 0 )) || fail "--output may be specified only once"
      requested_output="$2"
      output_seen=1
      shift 2
      ;;
    --ca-validity-days)
      [[ $# -ge 2 ]] || fail "--ca-validity-days requires a value"
      (( ca_days_seen == 0 )) || fail "--ca-validity-days may be specified only once"
      ca_validity_days="$2"
      ca_days_seen=1
      shift 2
      ;;
    --leaf-validity-days)
      [[ $# -ge 2 ]] || fail "--leaf-validity-days requires a value"
      (( leaf_days_seen == 0 )) || fail "--leaf-validity-days may be specified only once"
      leaf_validity_days="$2"
      leaf_days_seen=1
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

[[ "${project}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || \
  fail "--project is required and must be a valid project ID"
[[ -n "${requested_output}" ]] || fail "--output is required"
[[ "${ca_validity_days}" =~ ^[0-9]+$ ]] || fail "--ca-validity-days must be an integer"
[[ "${leaf_validity_days}" =~ ^[0-9]+$ ]] || fail "--leaf-validity-days must be an integer"
(( ca_validity_days >= minimum_ca_validity_days && ca_validity_days <= maximum_ca_validity_days )) || \
  fail "--ca-validity-days must be between ${minimum_ca_validity_days} and ${maximum_ca_validity_days}"
(( leaf_validity_days >= minimum_leaf_validity_days && leaf_validity_days <= maximum_leaf_validity_days )) || \
  fail "--leaf-validity-days must be between ${minimum_leaf_validity_days} and ${maximum_leaf_validity_days}"
(( leaf_validity_days < ca_validity_days )) || \
  fail "--leaf-validity-days must be shorter than --ca-validity-days"

for command_name in env python3 openssl mktemp chmod stat id git dirname basename find cp rm rmdir; do
  need_command "${command_name}"
done
[[ -x "${bootstrap_script}" ]] || fail "bootstrap validator is unavailable"
ulimit -c 0 || fail "cannot disable core dumps for key generation"

output="$(python3 -I - "${requested_output}" "$(id -u)" <<'PY'
import os
import stat
import sys

requested, expected_uid = sys.argv[1], int(sys.argv[2])
if not requested or any(ord(character) < 0x20 or ord(character) == 0x7F for character in requested):
    raise SystemExit("output path must not be empty or contain control characters")
if not os.path.isabs(requested):
    raise SystemExit("output path must be absolute")
clean = os.path.normpath(requested)
if clean != requested or os.path.basename(clean) in {"", ".", ".."}:
    raise SystemExit("output path must be normalized")
if os.path.lexists(clean):
    raise SystemExit("output path must not already exist")
parent = os.path.dirname(clean)
try:
    parent_stat = os.lstat(parent)
except OSError:
    raise SystemExit("output parent must already exist")
if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
    raise SystemExit("output parent must be a real directory, not a symlink")
real_parent = os.path.realpath(parent)
if real_parent != parent:
    raise SystemExit("output parent path must not contain symlink components")
if parent_stat.st_uid != expected_uid:
    raise SystemExit("output parent must be owned by the current user")
if stat.S_IMODE(parent_stat.st_mode) != 0o700:
    raise SystemExit("output parent permissions must be exactly 0700")
canonical = os.path.join(real_parent, os.path.basename(clean))
if os.path.lexists(canonical):
    raise SystemExit("output path must not already exist")
print(canonical)
PY
)" || fail "output path safety validation failed"

output_parent="$(dirname -- "${output}")"
validate_outside_git "${output_parent}" || fail "output must live outside every Git worktree and Git metadata directory"
output_parent_identity="$(python3 -I - "${output_parent}" <<'PY'
import os
import sys

metadata = os.lstat(sys.argv[1])
print(f"{metadata.st_dev}:{metadata.st_ino}")
PY
)" || fail "cannot record output parent identity"
[[ "${output_parent_identity}" =~ ^[0-9]+:[0-9]+$ ]] || fail "output parent identity is invalid"

temp_dir="$(mktemp -d "${output_parent}/.kagent-substrate-bundle.XXXXXX")"
[[ -d "${temp_dir}" && ! -L "${temp_dir}" ]] || fail "failed to create a private staging directory"
chmod 0700 "${temp_dir}"
[[ "$(portable_owner "${temp_dir}")" == "$(id -u)" ]] || fail "private staging directory has the wrong owner"
temp_mode="$(portable_mode "${temp_dir}")"
(( (8#${temp_mode} & 0777) == 0700 )) || fail "private staging directory permissions must be 0700"

make_ca api-server-ca 'yourown.chat Substrate API Server Root CA'
make_ca api-client-ca 'yourown.chat Substrate API Client Root CA'
make_ca egress-server-ca 'yourown.chat Substrate Egress Server Root CA'
make_ca actor-ca 'yourown.chat Substrate Actor Root CA'

make_leaf api-server \
  'yourown.chat Substrate API Server' \
  api-server-ca \
  serverAuth \
  'DNS:api.ate-system.svc'
make_leaf controller-client \
  'yourown.chat Substrate Controller Client' \
  api-client-ca \
  clientAuth \
  'URI:spiffe://cluster.local/ns/ate-system/sa/ate-controller'
make_leaf egress-client \
  'yourown.chat Substrate Egress Authorizer Client' \
  api-client-ca \
  clientAuth \
  'URI:spiffe://cluster.local/ns/ate-system/sa/atenet-egress'
make_leaf kagent-client \
  'yourown.chat kagent Production Controller Client' \
  api-client-ca \
  clientAuth \
  'URI:spiffe://cluster.local/ns/kagent-system/sa/kagent-controller'
make_leaf kagent-dev-client \
  'yourown.chat kagent Development Controller Client' \
  api-client-ca \
  clientAuth \
  'URI:spiffe://cluster.local/ns/kagent-dev/sa/kagent-controller'
make_leaf egress-server \
  'yourown.chat Substrate Egress Server' \
  egress-server-ca \
  serverAuth \
  'DNS:atenet-egress.ate-system.svc'

openssl_step 'JWT authority private key' genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -out "${temp_dir}/jwt-authority.key.pem"
openssl_step 'JWT authority PKCS8 key' pkcs8 \
  -topk8 \
  -nocrypt \
  -in "${temp_dir}/jwt-authority.key.pem" \
  -outform DER \
  -out "${temp_dir}/jwt-authority.key.der"
openssl_step 'actor CA PKCS8 key' pkcs8 \
  -topk8 \
  -nocrypt \
  -in "${temp_dir}/actor-ca.key.pem" \
  -outform DER \
  -out "${temp_dir}/actor-ca.key.der"
openssl_step 'actor CA DER certificate' x509 \
  -in "${temp_dir}/actor-ca.cert.pem" \
  -outform DER \
  -out "${temp_dir}/actor-ca.cert.der"

bundle_temp="${temp_dir}/operator-bundle.json"
python3 -I - "${temp_dir}" "${project}" "${bundle_temp}" <<'PY' || \
  fail "failed to assemble the fixed operator bundle"
import base64
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
project = sys.argv[2]
destination = pathlib.Path(sys.argv[3])

def read(name):
    value = (root / name).read_bytes()
    if not value:
        raise RuntimeError("empty generated artifact")
    return value

def encoded(name):
    return base64.b64encode(read(name)).decode("ascii")

def encoded_json(value):
    payload = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return base64.b64encode(payload).decode("ascii")

jwt_pool = {
    "Authorities": [{
        "ID": "1",
        "Algorithm": "ES256",
        "SigningKeyPKCS8": encoded("jwt-authority.key.der"),
        "SigningKeyPEM": "",
    }],
}
actor_ca_pool = {
    "CAs": [{
        "ID": "1",
        "SigningKeyPKCS8": encoded("actor-ca.key.der"),
        "SigningKeyPEM": "",
        "RootCertificateDER": encoded("actor-ca.cert.der"),
        "RootCertificatePEM": "",
        "IntermediateCertificatesDER": None,
    }],
}

document = {
    "schema": "yourown.chat/kagent-substrate-native-secret-bundle/v1",
    "projectId": project,
    "secrets": {
        "postgres": {
            "secretManagerId": "substrate-database-url",
            "namespace": "ate-system",
            "kubernetesName": "substrate-cloud-sql",
            "source": "existing-raw",
        },
        "api_tls": {
            "secretManagerId": "substrate-ate-api-tls",
            "namespace": "ate-system",
            "kubernetesName": "substrate-ate-api-tls",
            "source": "operator-envelope-v1",
            "data": {
                "server-credential-bundle.pem": encoded("api-server.bundle.pem"),
                "client-ca.pem": encoded("api-client-ca.cert.pem"),
            },
        },
        "controller_tls": {
            "secretManagerId": "substrate-ate-controller-tls",
            "namespace": "ate-system",
            "kubernetesName": "substrate-ate-controller-tls",
            "source": "operator-envelope-v1",
            "data": {
                "client-credential-bundle.pem": encoded("controller-client.bundle.pem"),
                "server-ca.pem": encoded("api-server-ca.cert.pem"),
            },
        },
        "egress_gateway_tls": {
            "secretManagerId": "substrate-atenet-egress-server-tls",
            "namespace": "ate-system",
            "kubernetesName": "substrate-atenet-egress-server-tls",
            "source": "operator-envelope-v1",
            "data": {
                "server-credential-bundle.pem": encoded("egress-server.bundle.pem"),
                "server-ca.pem": encoded("egress-server-ca.cert.pem"),
            },
        },
        "egress_authorizer_tls": {
            "secretManagerId": "substrate-atenet-egress-client-tls",
            "namespace": "ate-system",
            "kubernetesName": "substrate-atenet-egress-client-tls",
            "source": "operator-envelope-v1",
            "data": {
                "client-credential-bundle.pem": encoded("egress-client.bundle.pem"),
                "server-ca.pem": encoded("api-server-ca.cert.pem"),
            },
        },
        "actor_id_jwt_pool": {
            "secretManagerId": "substrate-actor-id-jwt-pool",
            "namespace": "ate-system",
            "kubernetesName": "actor-id-jwt-pool",
            "source": "operator-envelope-v1",
            "data": {"pool": encoded_json(jwt_pool)},
        },
        "actor_id_ca_pool": {
            "secretManagerId": "substrate-actor-id-ca-pool",
            "namespace": "ate-system",
            "kubernetesName": "actor-id-ca-pool",
            "source": "operator-envelope-v1",
            "data": {"pool": encoded_json(actor_ca_pool)},
        },
        "kagent_client_tls": {
            "secretManagerId": "kagent-ate-client-tls",
            "namespace": "kagent-system",
            "kubernetesName": "kagent-ate-client-tls",
            "source": "operator-envelope-v1",
            "data": {
                "client-credential-bundle.pem": encoded("kagent-client.bundle.pem"),
                "server-ca.pem": encoded("api-server-ca.cert.pem"),
            },
        },
        "kagent_dev_client_tls": {
            "secretManagerId": "kagent-dev-ate-client-tls",
            "namespace": "kagent-dev",
            "kubernetesName": "kagent-dev-ate-client-tls",
            "source": "operator-envelope-v1",
            "data": {
                "client-credential-bundle.pem": encoded("kagent-dev-client.bundle.pem"),
                "server-ca.pem": encoded("api-server-ca.cert.pem"),
            },
        },
    },
}

payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(destination, flags, 0o600)
try:
    with os.fdopen(descriptor, "wb", closefd=True) as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
except BaseException:
    try:
        os.unlink(destination)
    except OSError:
        pass
    raise
PY
chmod 0600 "${bundle_temp}"

validation_output=""
if ! validation_output="$(TMPDIR="${temp_dir}" "${bootstrap_script}" validate --project "${project}" --bundle "${bundle_temp}" 2>&1)"; then
  [[ -z "${validation_output}" ]] || printf '%s\n' "${validation_output}" >&2
  fail "generated operator bundle did not pass the existing bootstrap validator"
fi

validate_output_parent_snapshot "${output_parent}" "${output_parent_identity}" || \
  fail "output parent changed or became unsafe during generation"
validate_outside_git "${output_parent}" || fail "output parent entered a Git worktree during generation"

python3 -I - "${bundle_temp}" "${output_parent}" "$(basename -- "${output}")" "${output_parent_identity}" "$(id -u)" <<'PY' || \
  fail "output path appeared during generation; refusing to overwrite it"
import os
import stat
import sys

source, parent, destination_name, expected_identity, expected_uid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
source_stat = os.lstat(source)
if not stat.S_ISREG(source_stat.st_mode) or stat.S_ISLNK(source_stat.st_mode):
    raise SystemExit(1)
if source_stat.st_uid != expected_uid or stat.S_IMODE(source_stat.st_mode) != 0o600 or source_stat.st_nlink != 1:
    raise SystemExit(1)
flags = os.O_RDONLY
flags |= getattr(os, "O_DIRECTORY", 0)
flags |= getattr(os, "O_NOFOLLOW", 0)
parent_descriptor = os.open(parent, flags)
linked = False
try:
    parent_stat = os.fstat(parent_descriptor)
    if f"{parent_stat.st_dev}:{parent_stat.st_ino}" != expected_identity:
        raise SystemExit(1)
    if parent_stat.st_uid != expected_uid or stat.S_IMODE(parent_stat.st_mode) != 0o700:
        raise SystemExit(1)
    current_parent = os.lstat(parent)
    if (current_parent.st_dev, current_parent.st_ino) != (parent_stat.st_dev, parent_stat.st_ino):
        raise SystemExit(1)
    if os.path.realpath(parent) != parent:
        raise SystemExit(1)
    os.link(source, destination_name, dst_dir_fd=parent_descriptor, follow_symlinks=False)
    linked = True
    destination_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    destination_descriptor = os.open(destination_name, destination_flags, dir_fd=parent_descriptor)
    try:
        destination_stat = os.fstat(destination_descriptor)
        if not stat.S_ISREG(destination_stat.st_mode):
            raise SystemExit(1)
        if (destination_stat.st_dev, destination_stat.st_ino) != (source_stat.st_dev, source_stat.st_ino):
            raise SystemExit(1)
        if destination_stat.st_uid != expected_uid or stat.S_IMODE(destination_stat.st_mode) != 0o600:
            raise SystemExit(1)
        os.fsync(destination_descriptor)
    finally:
        os.close(destination_descriptor)
    os.fsync(parent_descriptor)
except BaseException:
    if linked:
        try:
            os.unlink(destination_name, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
        except OSError:
            pass
    raise
finally:
    os.close(parent_descriptor)
PY
published=1
rm -f -- "${bundle_temp}" || fail "failed to detach the published bundle from private staging"
chmod 0600 "${output}"
validate_output_parent_snapshot "${output_parent}" "${output_parent_identity}" || \
  fail "output parent changed or became unsafe while publishing"
validate_outside_git "${output_parent}" || fail "output parent entered a Git worktree while publishing"
[[ -f "${output}" && ! -L "${output}" ]] || fail "published output is not a regular file"
[[ "$(portable_owner "${output}")" == "$(id -u)" ]] || fail "published output has the wrong owner"
[[ "$(portable_link_count "${output}")" == "1" ]] || fail "published output must not be hard-linked"
output_mode="$(portable_mode "${output}")"
(( (8#${output_mode} & 0777) == 0600 )) || fail "published output permissions must be 0600"

python3 -I - "${output}" "${output_parent}" "${output_parent_identity}" <<'PY' || fail "failed to durably publish the generated bundle"
import os
import stat
import sys

output, parent, expected_identity = sys.argv[1:]
parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(parent, parent_flags)
try:
    parent_stat = os.fstat(descriptor)
    if f"{parent_stat.st_dev}:{parent_stat.st_ino}" != expected_identity:
        raise SystemExit(1)
    file_descriptor = os.open(os.path.basename(output), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=descriptor)
    try:
        metadata = os.fstat(file_descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise SystemExit(1)
        os.fsync(file_descriptor)
    finally:
        os.close(file_descriptor)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
validate_output_parent_snapshot "${output_parent}" "${output_parent_identity}" || \
  fail "output parent changed or became unsafe before completion"
validate_outside_git "${output_parent}" || fail "output parent entered a Git worktree before completion"

printf '%s\n' "${validation_output}"
printf 'created fresh kagent/Substrate operator bundle at %s (CA %s days, leaf %s days)\n' \
  "${output}" "${ca_validity_days}" "${leaf_validity_days}"
