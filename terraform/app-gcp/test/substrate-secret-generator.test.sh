#!/usr/bin/env bash
set -euo pipefail

umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
generator="${app_dir}/scripts/generate-kagent-substrate-operator-bundle.sh"
bootstrap="${app_dir}/scripts/bootstrap-kagent-substrate-secrets.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/substrate-secret-generator-test.XXXXXX")"
work="$(cd "${work}" && pwd -P)"
chmod 0700 "${work}"

cleanup() {
  find "${work}" -type f -exec chmod 0600 -- {} + 2>/dev/null || true
  find "${work}" -type f -exec rm -f -- {} +
  find "${work}" -depth -type d -exec rmdir -- {} + 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'substrate secret generator test failed: %s\n' "$*" >&2
  exit 1
}

portable_mode() {
  local value=""
  value="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  if [[ ! "${value}" =~ ^[0-7]{3,4}$ ]]; then
    value="$(stat -c '%a' "$1" 2>/dev/null || true)"
  fi
  printf '%s\n' "${value}"
}

portable_links() {
  local value=""
  value="$(stat -f '%l' "$1" 2>/dev/null || true)"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    value="$(stat -c '%h' "$1" 2>/dev/null || true)"
  fi
  printf '%s\n' "${value}"
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >"${work}/unexpected.stdout" 2>"${work}/expected.stderr"; then
    fail "${label} unexpectedly succeeded"
  fi
}

secure_parent="${work}/output"
mkdir "${secure_parent}"
chmod 0700 "${secure_parent}"
bundle="${secure_parent}/operator-bundle.json"
ambient_tmp="${work}/ambient-tmp"
mkdir "${ambient_tmp}"
chmod 0700 "${ambient_tmp}"

env TMPDIR="${ambient_tmp}" "${generator}" \
  --project test-project \
  --output "${bundle}" \
  >"${work}/generator.stdout" 2>"${work}/generator.stderr"

[[ -f "${bundle}" && ! -L "${bundle}" ]] || fail "generator did not create a regular bundle"
[[ "$(portable_mode "${bundle}")" == "600" ]] || fail "generated bundle mode is not 0600"
[[ "$(portable_links "${bundle}")" == "1" ]] || fail "generated bundle remains hard-linked"
[[ ! -s "${work}/generator.stderr" ]] || fail "successful generation wrote diagnostics to stderr"
grep -Fq 'validated nine-source contract' "${work}/generator.stdout" || fail "generator did not invoke the bootstrap validator"
grep -Fq "created fresh kagent/Substrate operator bundle at ${bundle}" "${work}/generator.stdout" || fail "generator success diagnostic is missing"
[[ -z "$(find "${ambient_tmp}" -mindepth 1 -print -quit)" ]] || fail "generator validator wrote private staging into ambient TMPDIR"
if rg -q -- 'BEGIN [A-Z0-9 ]*PRIVATE KEY|SigningKeyPKCS8|RootCertificateDER' "${work}/generator.stdout" "${work}/generator.stderr"; then
  fail "generator output leaked or named private payload material"
fi

decoded="${work}/decoded"
mkdir "${decoded}"
chmod 0700 "${decoded}"
python3 -I - "${bundle}" "${decoded}" <<'PY'
import base64
import json
import os
import pathlib
import re
import sys

bundle_path, output_path = sys.argv[1:]
output = pathlib.Path(output_path)
document = json.loads(pathlib.Path(bundle_path).read_text(encoding="utf-8"))
expected = {
    "postgres": ("existing-raw", []),
    "api_tls": ("operator-envelope-v1", ["server-credential-bundle.pem", "client-ca.pem"]),
    "controller_tls": ("operator-envelope-v1", ["client-credential-bundle.pem", "server-ca.pem"]),
    "egress_gateway_tls": ("operator-envelope-v1", ["server-credential-bundle.pem", "server-ca.pem"]),
    "egress_authorizer_tls": ("operator-envelope-v1", ["client-credential-bundle.pem", "server-ca.pem"]),
    "actor_id_jwt_pool": ("operator-envelope-v1", ["pool"]),
    "actor_id_ca_pool": ("operator-envelope-v1", ["pool"]),
    "kagent_client_tls": ("operator-envelope-v1", ["client-credential-bundle.pem", "server-ca.pem"]),
    "kagent_dev_client_tls": ("operator-envelope-v1", ["client-credential-bundle.pem", "server-ca.pem"]),
}
assert set(document) == {"schema", "projectId", "secrets"}
assert document["schema"] == "yourown.chat/kagent-substrate-native-secret-bundle/v1"
assert document["projectId"] == "test-project"
assert set(document["secrets"]) == set(expected)

pem_pattern = re.compile(br"-----BEGIN ([A-Z0-9 ]+)-----.*?-----END \1-----", re.DOTALL)
for logical, (source, keys) in expected.items():
    record = document["secrets"][logical]
    assert record["source"] == source
    if not keys:
        assert "data" not in record
        continue
    assert set(record["data"]) == set(keys)
    for key in keys:
        raw = base64.b64decode(record["data"][key], validate=True)
        assert raw
        destination = output / f"{logical}--{key}"
        destination.write_bytes(raw)
        os.chmod(destination, 0o600)
        if key.endswith("credential-bundle.pem"):
            blocks = list(pem_pattern.finditer(raw))
            assert len(blocks) == 2
            assert blocks[0].group(1) in {b"PRIVATE KEY", b"EC PRIVATE KEY"}
            assert blocks[1].group(1) == b"CERTIFICATE"
            assert not raw[:blocks[0].start()].strip() and not raw[blocks[-1].end():].strip()

jwt = json.loads((output / "actor_id_jwt_pool--pool").read_text())
assert len(jwt["Authorities"]) == 1
assert jwt["Authorities"][0]["ID"] == "1"
assert jwt["Authorities"][0]["Algorithm"] == "ES256"
(output / "jwt.key.der").write_bytes(base64.b64decode(jwt["Authorities"][0]["SigningKeyPKCS8"], validate=True))

actor = json.loads((output / "actor_id_ca_pool--pool").read_text())
assert len(actor["CAs"]) == 1
assert actor["CAs"][0]["ID"] == "1"
assert actor["CAs"][0]["IntermediateCertificatesDER"] is None
(output / "actor.key.der").write_bytes(base64.b64decode(actor["CAs"][0]["SigningKeyPKCS8"], validate=True))
(output / "actor.cert.der").write_bytes(base64.b64decode(actor["CAs"][0]["RootCertificateDER"], validate=True))
for name in ("jwt.key.der", "actor.key.der", "actor.cert.der"):
    os.chmod(output / name, 0o600)
PY

openssl x509 -inform DER -in "${decoded}/actor.cert.der" -outform PEM -out "${decoded}/actor-ca.pem" >/dev/null 2>&1

api_root="${decoded}/controller_tls--server-ca.pem"
api_client_root="${decoded}/api_tls--client-ca.pem"
egress_root="${decoded}/egress_gateway_tls--server-ca.pem"
actor_root="${decoded}/actor-ca.pem"
cmp -s "${api_root}" "${decoded}/egress_authorizer_tls--server-ca.pem" || fail "atenet authorizer API trust root differs"
cmp -s "${api_root}" "${decoded}/kagent_client_tls--server-ca.pem" || fail "kagent API trust root differs"
cmp -s "${api_root}" "${decoded}/kagent_dev_client_tls--server-ca.pem" || fail "kagent dev API trust root differs"

for root in "${api_root}" "${api_client_root}" "${egress_root}" "${actor_root}"; do
  openssl verify -check_ss_sig -CAfile "${root}" "${root}" >/dev/null 2>&1 || fail "generated root is not self-signed"
  openssl x509 -in "${root}" -noout -checkend $((365 * 24 * 60 * 60 - 600)) >/dev/null 2>&1 || fail "generated root lifetime is below the documented minimum"
  openssl x509 -in "${root}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -text -noout 2>/dev/null | rg -q -- 'prime256v1|P-256' || fail "generated root is not P-256"
  openssl x509 -in "${root}" -text -noout 2>/dev/null | rg -q -- 'Signature Algorithm: ecdsa-with-SHA256' || fail "generated root is not SHA-256 signed"
  openssl x509 -in "${root}" -text -noout 2>/dev/null | rg -q -- 'CA:TRUE' || fail "generated root lacks CA:TRUE"
  openssl x509 -in "${root}" -noout -ext keyUsage 2>/dev/null | rg -q -- 'Certificate Sign' || fail "generated root lacks keyCertSign"
done

credential_files=(
  "${decoded}/api_tls--server-credential-bundle.pem"
  "${decoded}/egress_gateway_tls--server-credential-bundle.pem"
  "${decoded}/controller_tls--client-credential-bundle.pem"
  "${decoded}/egress_authorizer_tls--client-credential-bundle.pem"
  "${decoded}/kagent_client_tls--client-credential-bundle.pem"
  "${decoded}/kagent_dev_client_tls--client-credential-bundle.pem"
)
ca_files=("${api_root}" "${egress_root}" "${api_client_root}" "${api_client_root}" "${api_client_root}" "${api_client_root}")
purposes=(sslserver sslserver sslclient sslclient sslclient sslclient)
sans=(
  'DNS:api.ate-system.svc'
  'DNS:atenet-egress.ate-system.svc'
  'URI:spiffe://cluster.local/ns/ate-system/sa/ate-controller'
  'URI:spiffe://cluster.local/ns/ate-system/sa/atenet-egress'
  'URI:spiffe://cluster.local/ns/kagent-system/sa/kagent-controller'
  'URI:spiffe://cluster.local/ns/kagent-dev/sa/kagent-controller'
)

certificate_hashes="${work}/certificate-hashes"
public_key_hashes="${work}/public-key-hashes"
serials="${work}/serials"
: > "${certificate_hashes}"
: > "${public_key_hashes}"
: > "${serials}"

for root in "${api_root}" "${api_client_root}" "${egress_root}" "${actor_root}"; do
  openssl x509 -in "${root}" -outform DER 2>/dev/null | openssl dgst -sha256 >> "${certificate_hashes}"
  openssl x509 -in "${root}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 >> "${public_key_hashes}"
  openssl x509 -in "${root}" -noout -serial 2>/dev/null >> "${serials}"
done

index=0
while (( index < 6 )); do
  bundle_file="${credential_files[${index}]}"
  leaf="${decoded}/leaf-${index}.pem"
  key="${decoded}/leaf-${index}.key.pem"
  sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "${bundle_file}" > "${leaf}"
  sed -n '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/p' "${bundle_file}" > "${key}"
  openssl verify -purpose "${purposes[${index}]}" -CAfile "${ca_files[${index}]}" "${leaf}" >/dev/null 2>&1 || fail "generated leaf trust is invalid"
  openssl x509 -in "${leaf}" -noout -checkend $((30 * 24 * 60 * 60 - 600)) >/dev/null 2>&1 || fail "generated leaf lifetime is below the documented minimum"
  actual_san="$(openssl x509 -in "${leaf}" -noout -ext subjectAltName 2>/dev/null | sed '1d; s/^[[:space:]]*//; s/[[:space:]]*$//' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')"
  [[ "${actual_san}" == "${sans[${index}]}" ]] || fail "generated leaf SAN set is not exact"
  expected_eku='TLS Web Client Authentication'
  [[ "${purposes[${index}]}" == sslserver ]] && expected_eku='TLS Web Server Authentication'
  actual_eku="$(openssl x509 -in "${leaf}" -noout -ext extendedKeyUsage 2>/dev/null | sed '1d; s/^[[:space:]]*//; s/[[:space:]]*$//' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')"
  [[ "${actual_eku}" == "${expected_eku}" ]] || fail "generated leaf EKU set is not exact"
  openssl pkey -in "${key}" -text -noout 2>/dev/null | rg -q -- 'prime256v1|P-256' || fail "generated leaf key is not P-256"
  openssl x509 -in "${leaf}" -text -noout 2>/dev/null | rg -q -- 'Signature Algorithm: ecdsa-with-SHA256' || fail "generated leaf is not SHA-256 signed"
  openssl x509 -in "${leaf}" -outform DER 2>/dev/null | openssl dgst -sha256 >> "${certificate_hashes}"
  openssl x509 -in "${leaf}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 >> "${public_key_hashes}"
  openssl x509 -in "${leaf}" -noout -serial 2>/dev/null >> "${serials}"
  index=$((index + 1))
done

openssl pkey -inform DER -in "${decoded}/jwt.key.der" -text -noout 2>/dev/null | rg -q -- 'prime256v1|P-256' || fail "JWT authority is not P-256"
openssl pkey -inform DER -in "${decoded}/jwt.key.der" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 >> "${public_key_hashes}"
[[ "$(sort -u "${certificate_hashes}" | wc -l | tr -d ' ')" == 10 ]] || fail "root and leaf certificates are not all distinct"
[[ "$(sort -u "${public_key_hashes}" | wc -l | tr -d ' ')" == 11 ]] || fail "root, leaf and JWT keys are not all distinct"
[[ "$(sort -u "${serials}" | wc -l | tr -d ' ')" == 10 ]] || fail "root and leaf serials are not all distinct"

"${bootstrap}" validate --project test-project --bundle "${bundle}" >/dev/null

custom_bundle="${secure_parent}/custom-lifetimes.json"
"${generator}" \
  --project test-project \
  --output "${custom_bundle}" \
  --ca-validity-days 400 \
  --leaf-validity-days 45 \
  >"${work}/custom-generator.stdout" 2>"${work}/custom-generator.stderr"
[[ -f "${custom_bundle}" && "$(portable_mode "${custom_bundle}")" == 600 && "$(portable_links "${custom_bundle}")" == 1 ]] || \
  fail "custom-lifetime generation did not publish a safe output"
grep -Fq '(CA 400 days, leaf 45 days)' "${work}/custom-generator.stdout" || fail "custom lifetime flags were not reported"
python3 -I - "${bundle}" "${custom_bundle}" <<'PY' || fail "two generator runs reused credential material"
import json
import pathlib
import sys

first = json.loads(pathlib.Path(sys.argv[1]).read_text())["secrets"]
second = json.loads(pathlib.Path(sys.argv[2]).read_text())["secrets"]
first_values = {value for record in first.values() for value in record.get("data", {}).values()}
second_values = {value for record in second.values() for value in record.get("data", {}).values()}
if first_values & second_values:
    raise SystemExit(1)
PY

expect_fail "existing output" "${generator}" --project test-project --output "${bundle}"
unsafe_parent="${work}/unsafe-parent"
mkdir "${unsafe_parent}"
chmod 0755 "${unsafe_parent}"
expect_fail "unsafe output parent" "${generator}" --project test-project --output "${unsafe_parent}/bundle.json"

symlink_parent="${work}/symlink-parent"
ln -s "${secure_parent}" "${symlink_parent}"
expect_fail "symlink output parent" "${generator}" --project test-project --output "${symlink_parent}/bundle.json"

touch "${secure_parent}/hardlink-source"
ln "${secure_parent}/hardlink-source" "${secure_parent}/hardlink-output"
expect_fail "existing hard-link output" "${generator}" --project test-project --output "${secure_parent}/hardlink-output"

git_parent="${work}/git-parent"
mkdir "${git_parent}"
chmod 0700 "${git_parent}"
git -C "${git_parent}" init -q
expect_fail "output inside Git worktree" "${generator}" --project test-project --output "${git_parent}/bundle.json"
expect_fail "ambient Git override cannot hide worktree" env GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent \
  "${generator}" --project test-project --output "${git_parent}/ambient-bypass.json"

expect_fail "leaf lifetime below minimum" "${generator}" --project test-project --output "${secure_parent}/too-short.json" --leaf-validity-days 29
expect_fail "leaf lifetime not shorter than CA" "${generator}" --project test-project --output "${secure_parent}/not-shorter.json" --ca-validity-days 365 --leaf-validity-days 365

race_output="${secure_parent}/race-output"
(
  while ! find "${secure_parent}" -maxdepth 1 -type d -name '.kagent-substrate-bundle.*' | grep -q .; do
    sleep 0.01
  done
  mkdir "${race_output}"
  chmod 0700 "${race_output}"
) &
watcher_pid=$!
expect_fail "concurrent output directory" "${generator}" --project test-project --output "${race_output}"
wait "${watcher_pid}"
[[ -d "${race_output}" && "$(portable_mode "${race_output}")" == "700" ]] || fail "concurrent destination directory was mutated"
[[ -z "$(find "${race_output}" -mindepth 1 -print -quit)" ]] || fail "secret payload was stranded under a concurrent destination directory"

mode_race_parent="${work}/mode-race-parent"
mkdir "${mode_race_parent}"
chmod 0700 "${mode_race_parent}"
(
  while ! find "${mode_race_parent}" -maxdepth 1 -type d -name '.kagent-substrate-bundle.*' | grep -q .; do
    sleep 0.01
  done
  chmod 0755 "${mode_race_parent}"
) &
watcher_pid=$!
expect_fail "output parent mode change" "${generator}" --project test-project --output "${mode_race_parent}/bundle.json"
wait "${watcher_pid}"
[[ ! -e "${mode_race_parent}/bundle.json" ]] || fail "bundle was published under a parent whose mode changed"
[[ -z "$(find "${mode_race_parent}" -maxdepth 1 -type d -name '.kagent-substrate-bundle.*' -print -quit)" ]] || fail "staging survived the parent-mode race"

symlink_race_parent="${work}/symlink-race-parent"
symlink_race_moved="${work}/symlink-race-parent-moved"
mkdir "${symlink_race_parent}"
chmod 0700 "${symlink_race_parent}"
(
  while ! find "${symlink_race_parent}" -maxdepth 1 -type d -name '.kagent-substrate-bundle.*' | grep -q .; do
    sleep 0.01
  done
  mv "${symlink_race_parent}" "${symlink_race_moved}"
  ln -s "${symlink_race_moved}" "${symlink_race_parent}"
) &
watcher_pid=$!
expect_fail "output parent symlink replacement" "${generator}" --project test-project --output "${symlink_race_parent}/bundle.json"
wait "${watcher_pid}"
[[ ! -e "${symlink_race_moved}/bundle.json" ]] || fail "bundle was published through a replaced parent symlink"
[[ -z "$(find "${symlink_race_moved}" -maxdepth 1 -type d -name '.kagent-substrate-bundle.*' -print -quit)" ]] || fail "staging survived the parent-symlink race"
rm "${symlink_race_parent}"
mv "${symlink_race_moved}" "${symlink_race_parent}"

[[ -z "$(find "${secure_parent}" -maxdepth 1 -type d -name '.kagent-substrate-bundle.*' -print -quit)" ]] || fail "private staging directory was not cleaned up"

printf 'substrate secret generator tests passed\n'
