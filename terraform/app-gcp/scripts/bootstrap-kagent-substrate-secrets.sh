#!/usr/bin/env bash
set -euo pipefail

umask 077

readonly bundle_schema="yourown.chat/kagent-substrate-native-secret-bundle/v1"
readonly payload_schema="yourown.chat/native-secret-envelope/v1"
readonly field_manager="yourown-chat-secret-bootstrap"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/../../.." && pwd -P)"
temp_dir=""

usage() {
  cat <<'USAGE'
Usage:
  bootstrap-kagent-substrate-secrets.sh validate --project PROJECT --bundle /secure/bundle.json
  bootstrap-kagent-substrate-secrets.sh bootstrap --project PROJECT --context KUBE_CONTEXT --bundle /secure/bundle.json
  bootstrap-kagent-substrate-secrets.sh sync --project PROJECT --context KUBE_CONTEXT

validate checks an owner-only operator bundle without contacting Google Cloud or
Kubernetes. bootstrap validates and uploads seven versioned envelopes, reads the
existing Cloud SQL URI, then synchronizes the exact native Secret contract.
sync reconstructs that contract from Secret Manager without an operator bundle.

The bundle must be a regular, non-symlink file owned by the current user, have
no group/other permission bits, and live outside this Git worktree.
USAGE
}

fail() {
  printf 'kagent/Substrate secret bootstrap failed: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

cleanup() {
  if [[ -n "${temp_dir}" && -d "${temp_dir}" ]]; then
    find "${temp_dir}" -type f -exec rm -f -- {} +
    find "${temp_dir}" -depth -type d -exec rmdir -- {} + 2>/dev/null || true
  fi
}

trap cleanup EXIT HUP INT TERM

source_contract_records() {
  cat <<'CONTRACT'
postgres|substrate-database-url|ate-system|substrate-cloud-sql|existing-raw|connection-string
api_tls|substrate-ate-api-tls|ate-system|substrate-ate-api-tls|operator-envelope-v1|server-credential-bundle.pem,client-ca.pem
controller_tls|substrate-ate-controller-tls|ate-system|substrate-ate-controller-tls|operator-envelope-v1|client-credential-bundle.pem,server-ca.pem
egress_gateway_tls|substrate-atenet-egress-server-tls|ate-system|substrate-atenet-egress-server-tls|operator-envelope-v1|server-credential-bundle.pem,server-ca.pem
egress_authorizer_tls|substrate-atenet-egress-client-tls|ate-system|substrate-atenet-egress-client-tls|operator-envelope-v1|client-credential-bundle.pem,server-ca.pem
actor_id_jwt_pool|substrate-actor-id-jwt-pool|ate-system|actor-id-jwt-pool|operator-envelope-v1|pool
actor_id_ca_pool|substrate-actor-id-ca-pool|ate-system|actor-id-ca-pool|operator-envelope-v1|pool
kagent_client_tls|kagent-ate-client-tls|kagent-system|kagent-ate-client-tls|operator-envelope-v1|client-credential-bundle.pem,server-ca.pem
CONTRACT
}

derived_contract_records() {
  cat <<'CONTRACT'
actor_id_ca_certs|actor_id_ca_pool|ate-system|actor-id-ca-certs|ca.crt
CONTRACT
}

record_field() {
  local logical="$1"
  local field="$2"
  source_contract_records | awk -F '|' -v logical="${logical}" -v field="${field}" '
    $1 == logical { print $field; found = 1; exit }
    END { if (!found) exit 1 }
  '
}

payload_path() {
  printf '%s/%s.payload.json\n' "${temp_dir}" "$1"
}

data_path() {
  printf '%s/%s.%s\n' "${temp_dir}" "$1" "$2"
}

portable_mode() {
  local value=""
  value="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  if [[ ! "${value}" =~ ^[0-7]{3,4}$ ]]; then
    value="$(stat -c '%a' "$1" 2>/dev/null || true)"
  fi
  [[ "${value}" =~ ^[0-7]{3,4}$ ]] || fail "cannot determine bundle permissions"
  printf '%s\n' "${value}"
}

portable_owner() {
  local value=""
  value="$(stat -f '%u' "$1" 2>/dev/null || true)"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    value="$(stat -c '%u' "$1" 2>/dev/null || true)"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "cannot determine bundle owner"
  printf '%s\n' "${value}"
}

validate_bundle_permissions() {
  local bundle_path="$1"
  local canonical=""
  local mode=""

  [[ -f "${bundle_path}" ]] || fail "bundle must be a regular file"
  [[ ! -L "${bundle_path}" ]] || fail "bundle must not be a symlink"
  [[ "$(portable_owner "${bundle_path}")" == "$(id -u)" ]] || fail "bundle must be owned by the current user"

  mode="$(portable_mode "${bundle_path}")"
  if (( (8#${mode} & 077) != 0 )); then
    fail "bundle permissions must not grant group or other access"
  fi

  canonical="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${bundle_path}")"
  case "${canonical}" in
    "${repo_root}"|"${repo_root}"/*)
      fail "bundle must live outside the Git worktree"
      ;;
  esac
}

validate_bundle_schema() {
  python3 - "$1" "$2" "${bundle_schema}" "${payload_schema}" <<'PY'
import base64
import json
import sys

path, project, bundle_schema, payload_schema = sys.argv[1:]

expected = {
    "postgres": ("substrate-database-url", "ate-system", "substrate-cloud-sql", "existing-raw", ["connection-string"]),
    "api_tls": ("substrate-ate-api-tls", "ate-system", "substrate-ate-api-tls", "operator-envelope-v1", ["server-credential-bundle.pem", "client-ca.pem"]),
    "controller_tls": ("substrate-ate-controller-tls", "ate-system", "substrate-ate-controller-tls", "operator-envelope-v1", ["client-credential-bundle.pem", "server-ca.pem"]),
    "egress_gateway_tls": ("substrate-atenet-egress-server-tls", "ate-system", "substrate-atenet-egress-server-tls", "operator-envelope-v1", ["server-credential-bundle.pem", "server-ca.pem"]),
    "egress_authorizer_tls": ("substrate-atenet-egress-client-tls", "ate-system", "substrate-atenet-egress-client-tls", "operator-envelope-v1", ["client-credential-bundle.pem", "server-ca.pem"]),
    "actor_id_jwt_pool": ("substrate-actor-id-jwt-pool", "ate-system", "actor-id-jwt-pool", "operator-envelope-v1", ["pool"]),
    "actor_id_ca_pool": ("substrate-actor-id-ca-pool", "ate-system", "actor-id-ca-pool", "operator-envelope-v1", ["pool"]),
    "kagent_client_tls": ("kagent-ate-client-tls", "kagent-system", "kagent-ate-client-tls", "operator-envelope-v1", ["client-credential-bundle.pem", "server-ca.pem"]),
}

def reject_constant(value):
    raise ValueError(f"non-standard JSON constant {value!r}")

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result

try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle, object_pairs_hook=unique_object, parse_constant=reject_constant)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"invalid operator bundle: {error}")

if not isinstance(document, dict) or set(document) != {"schema", "projectId", "secrets"}:
    raise SystemExit("operator bundle must contain exactly schema, projectId and secrets")
if document["schema"] != bundle_schema:
    raise SystemExit("operator bundle schema is not supported")
if document["projectId"] != project:
    raise SystemExit("operator bundle projectId does not match --project")
if not isinstance(document["secrets"], dict) or set(document["secrets"]) != set(expected):
    raise SystemExit("operator bundle must contain exactly the eight source Secret records")

for logical, (secret_id, namespace, name, source, keys) in expected.items():
    record = document["secrets"][logical]
    required = {"secretManagerId", "namespace", "kubernetesName", "source"}
    if source == "operator-envelope-v1":
        required.add("data")
    if not isinstance(record, dict) or set(record) != required:
        raise SystemExit(f"{logical} record has an unexpected shape")
    if (record["secretManagerId"], record["namespace"], record["kubernetesName"], record["source"]) != (secret_id, namespace, name, source):
        raise SystemExit(f"{logical} record does not match the fixed contract")
    if source == "existing-raw":
        continue
    data = record["data"]
    if not isinstance(data, dict) or set(data) != set(keys):
        raise SystemExit(f"{logical} data keys do not match the fixed contract")
    for key in keys:
        value = data[key]
        if not isinstance(value, str):
            raise SystemExit(f"{logical}/{key} must be a base64 string")
        try:
            decoded = base64.b64decode(value, validate=True)
        except (ValueError, base64.binascii.Error):
            raise SystemExit(f"{logical}/{key} is not canonical base64")
        if base64.b64encode(decoded).decode("ascii") != value:
            raise SystemExit(f"{logical}/{key} is not canonical base64")
        if not decoded:
            raise SystemExit(f"{logical}/{key} must not be empty")
    payload = json.dumps({"schema": payload_schema, "data": data}, separators=(",", ":"), sort_keys=True).encode()
    if len(payload) > 65536:
        raise SystemExit(f"{logical} envelope exceeds the Secret Manager 64 KiB limit")
PY
}

validate_payload_schema() {
  python3 - "$1" "$2" "${payload_schema}" <<'PY'
import base64
import json
import sys

path, logical, schema = sys.argv[1:]
keys = {
    "postgres": ["connection-string"],
    "api_tls": ["server-credential-bundle.pem", "client-ca.pem"],
    "controller_tls": ["client-credential-bundle.pem", "server-ca.pem"],
    "egress_gateway_tls": ["server-credential-bundle.pem", "server-ca.pem"],
    "egress_authorizer_tls": ["client-credential-bundle.pem", "server-ca.pem"],
    "actor_id_jwt_pool": ["pool"],
    "actor_id_ca_pool": ["pool"],
    "kagent_client_tls": ["client-credential-bundle.pem", "server-ca.pem"],
    "actor_id_ca_certs": ["ca.crt"],
}

def reject_constant(value):
    raise ValueError(f"non-standard JSON constant {value!r}")

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result

try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle, object_pairs_hook=unique_object, parse_constant=reject_constant)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"invalid {logical} envelope: {error}")

if logical not in keys:
    raise SystemExit("unknown logical Secret")
if not isinstance(document, dict) or set(document) != {"schema", "data"} or document.get("schema") != schema:
    raise SystemExit(f"{logical} envelope has an unexpected shape or schema")
if not isinstance(document["data"], dict) or set(document["data"]) != set(keys[logical]):
    raise SystemExit(f"{logical} envelope data keys do not match the fixed contract")
for key in keys[logical]:
    value = document["data"][key]
    if not isinstance(value, str):
        raise SystemExit(f"{logical}/{key} must be a base64 string")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, base64.binascii.Error):
        raise SystemExit(f"{logical}/{key} is not canonical base64")
    if base64.b64encode(decoded).decode("ascii") != value:
        raise SystemExit(f"{logical}/{key} is not canonical base64")
    if not decoded:
        raise SystemExit(f"{logical}/{key} must not be empty")
if len(open(path, "rb").read()) > 65536:
    raise SystemExit(f"{logical} envelope exceeds the Secret Manager 64 KiB limit")
PY
}

prepare_bundle_payloads() {
  local logical=""
  local payload=""
  while IFS='|' read -r logical _ _ _ source _; do
    [[ "${source}" == "operator-envelope-v1" ]] || continue
    payload="$(payload_path "${logical}")"
    jq -c --arg logical "${logical}" --arg schema "${payload_schema}" \
      '{schema: $schema, data: .secrets[$logical].data}' "${bundle}" > "${payload}"
    validate_payload_schema "${payload}" "${logical}"
  done < <(source_contract_records)
}

materialize_payload() {
  local logical="$1"
  local payload="$2"
  local keys=""
  local key=""
  local encoded=""
  local destination=""

  validate_payload_schema "${payload}" "${logical}"
  keys="$(record_field "${logical}" 6)"
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    encoded="${temp_dir}/${logical}.${key}.base64"
    destination="$(data_path "${logical}" "${key}")"
    jq -er --arg key "${key}" '.data[$key]' "${payload}" > "${encoded}"
    openssl base64 -d -A -in "${encoded}" -out "${destination}" >/dev/null 2>&1 || \
      fail "${logical}/${key} cannot be decoded"
    rm -f -- "${encoded}"
    [[ -s "${destination}" ]] || fail "${logical}/${key} decoded to an empty value"
  done < <(printf '%s\n' "${keys}" | tr ',' '\n')
}

validate_ca_bundle() {
  local file="$1"
  local label="$2"
  if rg -q -- 'BEGIN (EC |RSA )?PRIVATE KEY' "${file}"; then
    fail "${label} trust bundle contains a private key"
  fi
  rg -q -- 'BEGIN CERTIFICATE' "${file}" || fail "${label} trust bundle contains no certificate"
  openssl crl2pkcs7 -nocrl -certfile "${file}" 2>/dev/null | \
    openssl pkcs7 -print_certs -noout >/dev/null 2>&1 || fail "${label} is not a valid PEM certificate bundle"
}

split_credential_bundle() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import os
import re
import sys

source, key_path, leaf_path, chain_path = sys.argv[1:]
data = open(source, "rb").read()
pattern = re.compile(br"-----BEGIN ([A-Z0-9 ]+)-----.*?-----END \1-----", re.DOTALL)
blocks = list(pattern.finditer(data))
if not blocks or data[:blocks[0].start()].strip() or data[blocks[-1].end():].strip():
    raise SystemExit("credential bundle contains data outside PEM blocks")
for left, right in zip(blocks, blocks[1:]):
    if data[left.end():right.start()].strip():
        raise SystemExit("credential bundle contains data between PEM blocks")
key_types = {b"PRIVATE KEY", b"RSA PRIVATE KEY", b"EC PRIVATE KEY"}
keys = [block for block in blocks if block.group(1) in key_types]
certs = [block for block in blocks if block.group(1) == b"CERTIFICATE"]
if len(keys) != 1 or blocks[0].group(1) not in key_types or len(certs) < 1 or len(blocks) != 1 + len(certs):
    raise SystemExit("credential bundle must be one private key followed by a leaf-first certificate chain")
for path, content in (
    (key_path, keys[0].group(0) + b"\n"),
    (leaf_path, certs[0].group(0) + b"\n"),
    (chain_path, b"\n".join(cert.group(0) for cert in certs[1:]) + (b"\n" if len(certs) > 1 else b"")),
):
    with open(path, "wb") as handle:
        handle.write(content)
    os.chmod(path, 0o600)
PY
}

verify_leaf_with_ca() {
  local prefix="$1"
  local ca_file="$2"
  local purpose="$3"

  validate_ca_bundle "${ca_file}" "${prefix}"
  if [[ -s "${prefix}.chain.pem" ]]; then
    openssl verify -purpose "${purpose}" -CAfile "${ca_file}" -untrusted "${prefix}.chain.pem" "${prefix}.leaf.pem" >/dev/null 2>&1 || \
      fail "${prefix} certificate chain is not trusted for ${purpose}"
  else
    openssl verify -purpose "${purpose}" -CAfile "${ca_file}" "${prefix}.leaf.pem" >/dev/null 2>&1 || \
      fail "${prefix} certificate chain is not trusted for ${purpose}"
  fi
}

require_san() {
  local leaf="$1"
  local san="$2"
  openssl x509 -in "${leaf}" -noout -ext subjectAltName 2>/dev/null | \
    tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
    grep -Fx -- "${san}" >/dev/null || fail "certificate is missing required SAN ${san}"
}

validate_credential_bundle() {
  local bundle_file="$1"
  local ca_file="$2"
  local purpose="$3"
  local san="$4"
  local prefix="$5"

  split_credential_bundle "${bundle_file}" "${prefix}.key.pem" "${prefix}.leaf.pem" "${prefix}.chain.pem" || \
    fail "${prefix} credential bundle layout is invalid"
  openssl pkey -in "${prefix}.key.pem" -noout >/dev/null 2>&1 || fail "${prefix} private key is invalid"
  openssl x509 -in "${prefix}.leaf.pem" -noout -checkend 0 >/dev/null 2>&1 || fail "${prefix} leaf certificate is invalid or expired"
  openssl pkey -in "${prefix}.key.pem" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 -binary > "${prefix}.key.hash"
  openssl x509 -in "${prefix}.leaf.pem" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -binary > "${prefix}.cert.hash"
  cmp -s "${prefix}.key.hash" "${prefix}.cert.hash" || fail "${prefix} private key does not match the leaf certificate"
  verify_leaf_with_ca "${prefix}" "${ca_file}" "${purpose}"
  require_san "${prefix}.leaf.pem" "${san}"
}

validate_pool_json() {
  python3 - "$1" "$2" <<'PY'
import base64
import json
import sys

path, kind = sys.argv[1:]

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result

try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle, object_pairs_hook=unique_object)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"invalid {kind} pool JSON: {error}")

if kind == "jwt":
    if not isinstance(document, dict) or set(document) != {"Authorities"} or not isinstance(document["Authorities"], list) or not document["Authorities"]:
        raise SystemExit("JWT pool must contain a non-empty Authorities array")
    expected = {"ID", "Algorithm", "SigningKeyPKCS8", "SigningKeyPEM"}
    ids = set()
    for item in document["Authorities"]:
        if not isinstance(item, dict) or set(item) != expected:
            raise SystemExit("JWT authority has an unexpected shape")
        if not isinstance(item["ID"], str) or not item["ID"] or item["ID"] in ids or item["Algorithm"] != "ES256" or item["SigningKeyPEM"] != "":
            raise SystemExit("JWT authority ID/algorithm/key encoding is invalid")
        ids.add(item["ID"])
        try:
            if not base64.b64decode(item["SigningKeyPKCS8"], validate=True):
                raise ValueError()
        except (TypeError, ValueError, base64.binascii.Error):
            raise SystemExit("JWT authority PKCS8 key is invalid")
elif kind == "ca":
    if not isinstance(document, dict) or set(document) != {"CAs"} or not isinstance(document["CAs"], list) or not document["CAs"]:
        raise SystemExit("CA pool must contain a non-empty CAs array")
    expected = {"ID", "SigningKeyPKCS8", "SigningKeyPEM", "RootCertificateDER", "RootCertificatePEM", "IntermediateCertificatesDER"}
    ids = set()
    for item in document["CAs"]:
        if not isinstance(item, dict) or set(item) != expected:
            raise SystemExit("CA entry has an unexpected shape")
        if not isinstance(item["ID"], str) or not item["ID"] or item["ID"] in ids or item["SigningKeyPEM"] != "" or item["RootCertificatePEM"] != "":
            raise SystemExit("CA entry ID/key/certificate encoding is invalid")
        ids.add(item["ID"])
        if item["IntermediateCertificatesDER"] is None:
            item["IntermediateCertificatesDER"] = []
        if not isinstance(item["IntermediateCertificatesDER"], list):
            raise SystemExit("CA intermediate chain must be null or an array")
        for field in ("SigningKeyPKCS8", "RootCertificateDER"):
            try:
                if not base64.b64decode(item[field], validate=True):
                    raise ValueError()
            except (TypeError, ValueError, base64.binascii.Error):
                raise SystemExit(f"CA entry {field} is invalid")
        for value in item["IntermediateCertificatesDER"]:
            try:
                if not base64.b64decode(value, validate=True):
                    raise ValueError()
            except (TypeError, ValueError, base64.binascii.Error):
                raise SystemExit("CA intermediate certificate is invalid")
else:
    raise SystemExit("unknown pool kind")
PY
}

decode_json_base64_field() {
  local json_file="$1"
  local expression="$2"
  local destination="$3"
  local encoded="${destination}.base64"
  jq -er "${expression}" "${json_file}" > "${encoded}"
  openssl base64 -d -A -in "${encoded}" -out "${destination}" >/dev/null 2>&1 || fail "pool contains invalid base64"
  rm -f -- "${encoded}"
}

validate_jwt_pool() {
  local pool="$1"
  local count=""
  local index=0
  local key_file=""
  validate_pool_json "${pool}" jwt
  count="$(jq -er '.Authorities | length' "${pool}")"
  while (( index < count )); do
    key_file="${temp_dir}/jwt-authority-${index}.der"
    decode_json_base64_field "${pool}" ".Authorities[${index}].SigningKeyPKCS8" "${key_file}"
    openssl pkey -inform DER -in "${key_file}" -text -noout 2>/dev/null | \
      grep -Eq -- 'prime256v1|P-256' || fail "JWT authority ${index} is not an ECDSA P-256 private key"
    index=$((index + 1))
  done
}

validate_ca_pool_and_derive() {
  local pool="$1"
  local count=""
  local index=0
  local key_file=""
  local cert_file=""
  local key_hash=""
  local cert_hash=""

  validate_pool_json "${pool}" ca
  count="$(jq -er '.CAs | length' "${pool}")"
  while (( index < count )); do
    key_file="${temp_dir}/actor-ca-${index}.key.der"
    cert_file="${temp_dir}/actor-ca-${index}.cert.der"
    key_hash="${temp_dir}/actor-ca-${index}.key.hash"
    cert_hash="${temp_dir}/actor-ca-${index}.cert.hash"
    decode_json_base64_field "${pool}" ".CAs[${index}].SigningKeyPKCS8" "${key_file}"
    decode_json_base64_field "${pool}" ".CAs[${index}].RootCertificateDER" "${cert_file}"
    openssl pkey -inform DER -in "${key_file}" -noout >/dev/null 2>&1 || fail "actor CA ${index} private key is invalid"
    openssl x509 -inform DER -in "${cert_file}" -noout -checkend 0 >/dev/null 2>&1 || fail "actor CA ${index} certificate is invalid or expired"
    openssl x509 -inform DER -in "${cert_file}" -text -noout 2>/dev/null | grep -Fq 'CA:TRUE' || fail "actor CA ${index} certificate is not a CA"
    openssl pkey -inform DER -in "${key_file}" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 -binary > "${key_hash}"
    openssl x509 -inform DER -in "${cert_file}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -binary > "${cert_hash}"
    cmp -s "${key_hash}" "${cert_hash}" || fail "actor CA ${index} private key does not match its root certificate"
    index=$((index + 1))
  done

  openssl x509 -inform DER -in "${temp_dir}/actor-ca-0.cert.der" -outform PEM -out "$(data_path actor_id_ca_certs ca.crt)" >/dev/null 2>&1
  validate_ca_bundle "$(data_path actor_id_ca_certs ca.crt)" "derived actor-id-ca-certs/ca.crt"
  jq -Rs --arg schema "${payload_schema}" \
    '{schema: $schema, data: {"ca.crt": @base64}}' "$(data_path actor_id_ca_certs ca.crt)" > "$(payload_path actor_id_ca_certs)"
  validate_payload_schema "$(payload_path actor_id_ca_certs)" actor_id_ca_certs
}

validate_postgres_uri() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

raw = open(sys.argv[1], "rb").read()
if not raw or b"\x00" in raw or raw.endswith(b"\n") or b"\n" in raw or b"\r" in raw:
    raise SystemExit("PostgreSQL connection string must be one non-empty line without NUL")
try:
    value = raw.decode("utf-8")
    parsed = urlsplit(value)
    port = parsed.port
except (UnicodeError, ValueError):
    raise SystemExit("PostgreSQL connection string is not a valid UTF-8 URI")
if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname or not parsed.username or parsed.password is None or parsed.path in {"", "/"}:
    raise SystemExit("PostgreSQL connection string is missing scheme, credentials, host or database")
if port is not None and port != 5432:
    raise SystemExit("PostgreSQL connection string must use port 5432 when a port is explicit")
PY
}

validate_materialized_contract() {
  local postgres_file="$(data_path postgres connection-string)"
  local api_bundle="$(data_path api_tls server-credential-bundle.pem)"
  local api_client_ca="$(data_path api_tls client-ca.pem)"
  local controller_bundle="$(data_path controller_tls client-credential-bundle.pem)"
  local controller_server_ca="$(data_path controller_tls server-ca.pem)"
  local egress_server_bundle="$(data_path egress_gateway_tls server-credential-bundle.pem)"
  local egress_server_ca="$(data_path egress_gateway_tls server-ca.pem)"
  local egress_client_bundle="$(data_path egress_authorizer_tls client-credential-bundle.pem)"
  local egress_client_server_ca="$(data_path egress_authorizer_tls server-ca.pem)"
  local kagent_bundle="$(data_path kagent_client_tls client-credential-bundle.pem)"
  local kagent_server_ca="$(data_path kagent_client_tls server-ca.pem)"

  if [[ -f "${postgres_file}" ]]; then
    validate_postgres_uri "${postgres_file}"
  fi
  validate_jwt_pool "$(data_path actor_id_jwt_pool pool)"
  validate_ca_pool_and_derive "$(data_path actor_id_ca_pool pool)"

  validate_ca_bundle "${api_client_ca}" "ate-api client CA"
  validate_ca_bundle "${controller_server_ca}" "controller ate-api server CA"
  validate_ca_bundle "${egress_server_ca}" "atenet gateway server CA"
  validate_ca_bundle "${egress_client_server_ca}" "atenet authorizer ate-api server CA"
  validate_ca_bundle "${kagent_server_ca}" "kagent ate-api server CA"

  validate_credential_bundle "${api_bundle}" "${controller_server_ca}" sslserver \
    'DNS:api.ate-system.svc' "${temp_dir}/api-server"
  verify_leaf_with_ca "${temp_dir}/api-server" "${egress_client_server_ca}" sslserver
  verify_leaf_with_ca "${temp_dir}/api-server" "${kagent_server_ca}" sslserver
  validate_credential_bundle "${egress_server_bundle}" "${egress_server_ca}" sslserver \
    'DNS:atenet-egress.ate-system.svc' "${temp_dir}/egress-server"
  validate_credential_bundle "${controller_bundle}" "${api_client_ca}" sslclient \
    'URI:spiffe://cluster.local/ns/ate-system/sa/ate-controller' "${temp_dir}/controller-client"
  validate_credential_bundle "${egress_client_bundle}" "${api_client_ca}" sslclient \
    'URI:spiffe://cluster.local/ns/ate-system/sa/atenet-egress' "${temp_dir}/egress-client"
  validate_credential_bundle "${kagent_bundle}" "${api_client_ca}" sslclient \
    'URI:spiffe://cluster.local/ns/kagent-system/sa/kagent-controller' "${temp_dir}/kagent-client"
}

ensure_secret_containers() {
  local logical=""
  local secret_id=""
  while IFS='|' read -r logical secret_id _; do
    gcloud secrets describe "${secret_id}" --project="${project}" --format='value(name)' >/dev/null || \
      fail "Secret Manager container is unavailable: ${secret_id}"
  done < <(source_contract_records)
}

fetch_postgres_payload() {
  local raw="$(data_path postgres connection-string)"
  local payload="$(payload_path postgres)"
  gcloud secrets versions access latest --secret="$(record_field postgres 2)" --project="${project}" --out-file="${raw}" >/dev/null || \
    fail "the existing Cloud SQL connection string is unavailable"
  validate_postgres_uri "${raw}"
  jq -Rs --arg schema "${payload_schema}" \
    '{schema: $schema, data: {"connection-string": @base64}}' "${raw}" > "${payload}"
  validate_payload_schema "${payload}" postgres
}

fetch_operator_payloads() {
  local logical=""
  local secret_id=""
  local source=""
  local payload=""
  while IFS='|' read -r logical secret_id _ _ source _; do
    [[ "${source}" == "operator-envelope-v1" ]] || continue
    payload="$(payload_path "${logical}")"
    rm -f -- "${payload}"
    gcloud secrets versions access latest --secret="${secret_id}" --project="${project}" --out-file="${payload}" >/dev/null || \
      fail "Secret Manager payload is unavailable: ${secret_id}"
    validate_payload_schema "${payload}" "${logical}"
  done < <(source_contract_records)
}

upload_operator_payloads() {
  local logical=""
  local secret_id=""
  local source=""
  local payload=""
  local fetched=""
  local version_name=""
  while IFS='|' read -r logical secret_id _ _ source _; do
    [[ "${source}" == "operator-envelope-v1" ]] || continue
    payload="$(payload_path "${logical}")"
    version_name="$(gcloud secrets versions add "${secret_id}" --project="${project}" --data-file="${payload}" --format='value(name)')" || \
      fail "failed to add a Secret Manager version for ${secret_id}"
    [[ -n "${version_name}" ]] || fail "Secret Manager returned no version identifier for ${secret_id}"
    fetched="${temp_dir}/${logical}.fetched.json"
    gcloud secrets versions access latest --secret="${secret_id}" --project="${project}" --out-file="${fetched}" >/dev/null || \
      fail "new Secret Manager version is unreadable: ${secret_id}"
    cmp -s "${payload}" "${fetched}" || fail "new Secret Manager version differs from the validated envelope: ${secret_id}"
    mv -f -- "${fetched}" "${payload}"
    printf 'added Secret Manager version %s\n' "${version_name}"
  done < <(source_contract_records)
}

materialize_all_payloads() {
  local logical=""
  while IFS='|' read -r logical _; do
    materialize_payload "${logical}" "$(payload_path "${logical}")"
  done < <(source_contract_records)
}

check_cluster_access() {
  local namespace=""
  for namespace in ate-system kagent-system; do
    kubectl --context="${context}" get namespace "${namespace}" -o name >/dev/null || \
      fail "namespace ${namespace} is unavailable in context ${context}"
    [[ "$(kubectl --context="${context}" auth can-i get secrets -n "${namespace}")" == "yes" ]] || \
      fail "context ${context} cannot get Secrets in ${namespace}"
    [[ "$(kubectl --context="${context}" auth can-i patch secrets -n "${namespace}")" == "yes" ]] || \
      fail "context ${context} cannot patch Secrets in ${namespace}"
  done
}

apply_payload() {
  local logical="$1"
  local namespace="$2"
  local name="$3"
  local payload="$4"
  local actual="${temp_dir}/${logical}.actual.json"

  jq -c --arg namespace "${namespace}" --arg name "${name}" '
    {
      apiVersion: "v1",
      kind: "Secret",
      metadata: {
        namespace: $namespace,
        name: $name,
        labels: {
          "app.kubernetes.io/managed-by": "yourown-chat-secret-bootstrap",
          "app.kubernetes.io/part-of": "kagent-substrate-testbed",
          "platform.yourown.chat/secret-contract": "v1"
        }
      },
      type: "Opaque",
      data: .data
    }
  ' "${payload}" | kubectl --context="${context}" apply --server-side --field-manager="${field_manager}" -f - -o name >/dev/null

  kubectl --context="${context}" -n "${namespace}" get secret "${name}" -o json > "${actual}"
  jq -e --slurpfile expected "${payload}" '
    .type == "Opaque" and
    .metadata.labels["app.kubernetes.io/managed-by"] == "yourown-chat-secret-bootstrap" and
    .metadata.labels["platform.yourown.chat/secret-contract"] == "v1" and
    .data == $expected[0].data
  ' "${actual}" >/dev/null || fail "synchronized Secret verification failed: ${namespace}/${name}"
  printf 'synchronized Kubernetes Secret %s/%s\n' "${namespace}" "${name}"
}

sync_kubernetes_contract() {
  local logical=""
  local namespace=""
  local name=""
  while IFS='|' read -r logical _ namespace name _; do
    apply_payload "${logical}" "${namespace}" "${name}" "$(payload_path "${logical}")"
  done < <(source_contract_records)
  while IFS='|' read -r logical _ namespace name _; do
    apply_payload "${logical}" "${namespace}" "${name}" "$(payload_path "${logical}")"
  done < <(derived_contract_records)
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
action="$1"
shift
project=""
context=""
bundle=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || fail "--project requires a value"
      project="$2"
      shift 2
      ;;
    --context)
      [[ $# -ge 2 ]] || fail "--context requires a value"
      context="$2"
      shift 2
      ;;
    --bundle)
      [[ $# -ge 2 ]] || fail "--bundle requires a value"
      bundle="$2"
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

case "${action}" in
  validate|bootstrap|sync) ;;
  *) usage >&2; fail "action must be validate, bootstrap or sync" ;;
esac

[[ "${project}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail "--project is required and must be a valid project ID"
if [[ "${action}" == "validate" || "${action}" == "bootstrap" ]]; then
  [[ -n "${bundle}" ]] || fail "--bundle is required for ${action}"
else
  [[ -z "${bundle}" ]] || fail "sync reads Secret Manager and does not accept --bundle"
fi
if [[ "${action}" == "bootstrap" || "${action}" == "sync" ]]; then
  [[ -n "${context}" && ! "${context}" =~ [[:cntrl:]] ]] || fail "--context is required"
fi

for command_name in python3 jq openssl stat id mktemp find awk sed grep rg cmp; do
  need_command "${command_name}"
done
if [[ "${action}" == "bootstrap" || "${action}" == "sync" ]]; then
  need_command gcloud
  need_command kubectl
fi

if [[ -n "${bundle}" ]]; then
  validate_bundle_permissions "${bundle}"
  validate_bundle_schema "${bundle}" "${project}"
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kagent-substrate-secrets.XXXXXX")"
[[ -d "${temp_dir}" ]] || fail "failed to create a private temporary directory"

case "${action}" in
  validate)
    prepare_bundle_payloads
    while IFS='|' read -r logical _ _ _ source _; do
      [[ "${source}" == "operator-envelope-v1" ]] || continue
      materialize_payload "${logical}" "$(payload_path "${logical}")"
    done < <(source_contract_records)
    validate_materialized_contract
    printf 'validated eight-source contract and derived ate-system/actor-id-ca-certs; PostgreSQL bytes are validated only during bootstrap/sync\n'
    ;;
  bootstrap)
    prepare_bundle_payloads
    while IFS='|' read -r logical _ _ _ source _; do
      [[ "${source}" == "operator-envelope-v1" ]] || continue
      materialize_payload "${logical}" "$(payload_path "${logical}")"
    done < <(source_contract_records)
    ensure_secret_containers
    fetch_postgres_payload
    validate_materialized_contract
    check_cluster_access
    upload_operator_payloads
    fetch_operator_payloads
    materialize_all_payloads
    validate_materialized_contract
    sync_kubernetes_contract
    ;;
  sync)
    ensure_secret_containers
    fetch_postgres_payload
    fetch_operator_payloads
    materialize_all_payloads
    validate_materialized_contract
    check_cluster_access
    sync_kubernetes_contract
    ;;
esac
