#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
app_dir="$(cd "${script_dir}/.." && pwd -P)"
repo_dir="$(cd "${app_dir}/../.." && pwd -P)"
bootstrap="${app_dir}/scripts/bootstrap-kagent-substrate-secrets.sh"
components="${app_dir}/components.tfcomponent.hcl"
service_inputs="${app_dir}/service-inputs.tfdeploy.hcl"
prerequisites="${app_dir}/modules/substrate-prerequisites/main.tf"
work="$(mktemp -d "${TMPDIR:-/tmp}/substrate-secret-bootstrap-test.XXXXXX")"

cleanup() {
  find "${work}" -type f -exec rm -f -- {} +
  find "${work}" -depth -type d -exec rmdir -- {} + 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'substrate secret bootstrap test failed: %s\n' "$*" >&2
  exit 1
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >"${work}/unexpected.stdout" 2>"${work}/expected.stderr"; then
    fail "${label} unexpectedly succeeded"
  fi
}

make_ca() {
  local name="$1"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${work}/${name}.key.pem" >/dev/null 2>&1
  openssl req -new -x509 -key "${work}/${name}.key.pem" -sha256 -days 2 \
    -subj "/CN=${name}" \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -out "${work}/${name}.cert.pem" >/dev/null 2>&1
}

make_leaf() {
  local name="$1"
  local ca="$2"
  local eku="$3"
  local san="$4"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${work}/${name}.key.pem" >/dev/null 2>&1
  openssl req -new -key "${work}/${name}.key.pem" -sha256 -subj "/CN=${name}" \
    -addext "subjectAltName=${san}" -addext "extendedKeyUsage=${eku}" \
    -out "${work}/${name}.csr.pem" >/dev/null 2>&1
  openssl x509 -req -in "${work}/${name}.csr.pem" \
    -CA "${work}/${ca}.cert.pem" -CAkey "${work}/${ca}.key.pem" -CAcreateserial \
    -sha256 -days 2 -copy_extensions copy -out "${work}/${name}.cert.pem" >/dev/null 2>&1
  {
    sed -n '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/p' "${work}/${name}.key.pem"
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "${work}/${name}.cert.pem"
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "${work}/${ca}.cert.pem"
  } > "${work}/${name}.bundle.pem"
}

encode_file() {
  openssl base64 -A -in "$1" -out "$2"
}

make_actor_ca_bundle_variant() {
  local variant="$1"
  local key_pem="$2"
  local cert_pem="$3"
  local output="$4"

  openssl pkcs8 -topk8 -nocrypt -in "${key_pem}" -outform DER -out "${work}/${variant}.key.der" >/dev/null 2>&1
  openssl x509 -in "${cert_pem}" -outform DER -out "${work}/${variant}.cert.der" >/dev/null 2>&1
  encode_file "${work}/${variant}.key.der" "${work}/${variant}.key.b64"
  encode_file "${work}/${variant}.cert.der" "${work}/${variant}.cert.b64"
  jq -n --rawfile key "${work}/${variant}.key.b64" --rawfile cert "${work}/${variant}.cert.b64" \
    '{CAs:[{ID:"1",SigningKeyPKCS8:$key,SigningKeyPEM:"",RootCertificateDER:$cert,RootCertificatePEM:"",IntermediateCertificatesDER:null}]}' \
    > "${work}/${variant}.pool.json"
  encode_file "${work}/${variant}.pool.json" "${work}/${variant}.pool.json.b64"
  jq --rawfile pool "${work}/${variant}.pool.json.b64" \
    '.secrets.actor_id_ca_pool.data.pool=$pool' \
    "${work}/bundle.json" > "${output}"
  chmod 0600 "${output}"
}

make_ca api-server-ca
make_ca api-client-ca
make_ca egress-server-ca
make_ca actor-identity-ca

make_leaf api-server api-server-ca serverAuth 'DNS:api.ate-system.svc'
make_leaf egress-server egress-server-ca serverAuth 'DNS:atenet-egress.ate-system.svc'
make_leaf controller-client api-client-ca clientAuth 'URI:spiffe://cluster.local/ns/ate-system/sa/ate-controller'
make_leaf egress-client api-client-ca clientAuth 'URI:spiffe://cluster.local/ns/ate-system/sa/atenet-egress'
make_leaf kagent-client api-client-ca clientAuth 'URI:spiffe://cluster.local/ns/kagent-system/sa/kagent-controller'
make_leaf kagent-dev-client api-client-ca clientAuth 'URI:spiffe://cluster.local/ns/kagent-dev/sa/kagent-controller'

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${work}/jwt.key.pem" >/dev/null 2>&1
openssl pkcs8 -topk8 -nocrypt -in "${work}/jwt.key.pem" -outform DER -out "${work}/jwt.key.der" >/dev/null 2>&1
openssl pkcs8 -topk8 -nocrypt -in "${work}/actor-identity-ca.key.pem" -outform DER -out "${work}/actor-ca.key.der" >/dev/null 2>&1
openssl x509 -in "${work}/actor-identity-ca.cert.pem" -outform DER -out "${work}/actor-ca.cert.der" >/dev/null 2>&1

encode_file "${work}/jwt.key.der" "${work}/jwt.key.b64"
encode_file "${work}/actor-ca.key.der" "${work}/actor-ca.key.b64"
encode_file "${work}/actor-ca.cert.der" "${work}/actor-ca.cert.b64"

jq -n --rawfile key "${work}/jwt.key.b64" '{Authorities:[{ID:"1",Algorithm:"ES256",SigningKeyPKCS8:$key,SigningKeyPEM:""}]}' > "${work}/jwt.pool.json"
jq -n --rawfile key "${work}/actor-ca.key.b64" --rawfile cert "${work}/actor-ca.cert.b64" \
  '{CAs:[{ID:"1",SigningKeyPKCS8:$key,SigningKeyPEM:"",RootCertificateDER:$cert,RootCertificatePEM:"",IntermediateCertificatesDER:null}]}' > "${work}/actor-ca.pool.json"

for file in \
  api-server.bundle.pem api-client-ca.cert.pem \
  controller-client.bundle.pem api-server-ca.cert.pem \
  egress-server.bundle.pem egress-server-ca.cert.pem \
  egress-client.bundle.pem kagent-client.bundle.pem kagent-dev-client.bundle.pem \
  jwt.pool.json actor-ca.pool.json; do
  encode_file "${work}/${file}" "${work}/${file}.b64"
done

jq -n \
  --rawfile api_bundle "${work}/api-server.bundle.pem.b64" \
  --rawfile api_client_ca "${work}/api-client-ca.cert.pem.b64" \
  --rawfile controller_bundle "${work}/controller-client.bundle.pem.b64" \
  --rawfile api_server_ca "${work}/api-server-ca.cert.pem.b64" \
  --rawfile egress_server_bundle "${work}/egress-server.bundle.pem.b64" \
  --rawfile egress_server_ca "${work}/egress-server-ca.cert.pem.b64" \
  --rawfile egress_client_bundle "${work}/egress-client.bundle.pem.b64" \
  --rawfile kagent_bundle "${work}/kagent-client.bundle.pem.b64" \
  --rawfile kagent_dev_bundle "${work}/kagent-dev-client.bundle.pem.b64" \
  --rawfile jwt_pool "${work}/jwt.pool.json.b64" \
  --rawfile actor_ca_pool "${work}/actor-ca.pool.json.b64" \
  '{
    schema:"yourown.chat/kagent-substrate-native-secret-bundle/v1",
    projectId:"test-project",
    secrets:{
      postgres:{secretManagerId:"substrate-database-url",namespace:"ate-system",kubernetesName:"substrate-cloud-sql",source:"existing-raw"},
      api_tls:{secretManagerId:"substrate-ate-api-tls",namespace:"ate-system",kubernetesName:"substrate-ate-api-tls",source:"operator-envelope-v1",data:{"server-credential-bundle.pem":$api_bundle,"client-ca.pem":$api_client_ca}},
      controller_tls:{secretManagerId:"substrate-ate-controller-tls",namespace:"ate-system",kubernetesName:"substrate-ate-controller-tls",source:"operator-envelope-v1",data:{"client-credential-bundle.pem":$controller_bundle,"server-ca.pem":$api_server_ca}},
      egress_gateway_tls:{secretManagerId:"substrate-atenet-egress-server-tls",namespace:"ate-system",kubernetesName:"substrate-atenet-egress-server-tls",source:"operator-envelope-v1",data:{"server-credential-bundle.pem":$egress_server_bundle,"server-ca.pem":$egress_server_ca}},
      egress_authorizer_tls:{secretManagerId:"substrate-atenet-egress-client-tls",namespace:"ate-system",kubernetesName:"substrate-atenet-egress-client-tls",source:"operator-envelope-v1",data:{"client-credential-bundle.pem":$egress_client_bundle,"server-ca.pem":$api_server_ca}},
      actor_id_jwt_pool:{secretManagerId:"substrate-actor-id-jwt-pool",namespace:"ate-system",kubernetesName:"actor-id-jwt-pool",source:"operator-envelope-v1",data:{pool:$jwt_pool}},
      actor_id_ca_pool:{secretManagerId:"substrate-actor-id-ca-pool",namespace:"ate-system",kubernetesName:"actor-id-ca-pool",source:"operator-envelope-v1",data:{pool:$actor_ca_pool}},
      kagent_client_tls:{secretManagerId:"kagent-ate-client-tls",namespace:"kagent-system",kubernetesName:"kagent-ate-client-tls",source:"operator-envelope-v1",data:{"client-credential-bundle.pem":$kagent_bundle,"server-ca.pem":$api_server_ca}},
      kagent_dev_client_tls:{secretManagerId:"kagent-dev-ate-client-tls",namespace:"kagent-dev",kubernetesName:"kagent-dev-ate-client-tls",source:"operator-envelope-v1",data:{"client-credential-bundle.pem":$kagent_dev_bundle,"server-ca.pem":$api_server_ca}}
    }
  }' > "${work}/bundle.json"
chmod 0600 "${work}/bundle.json"

validation_output="$(${bootstrap} validate --project test-project --bundle "${work}/bundle.json" 2>&1)"
[[ "${validation_output}" == *'validated nine-source contract and derived ate-system/actor-id-ca-certs'* ]] || fail "valid bundle did not pass"
[[ "${validation_output}" != *'BEGIN PRIVATE KEY'* ]] || fail "validation output leaked private material"

mkdir -p "${work}/sibling-git"
git -C "${work}/sibling-git" init -q
cp "${work}/bundle.json" "${work}/sibling-git/bundle.json"
chmod 0600 "${work}/sibling-git/bundle.json"
expect_fail "bundle inside another Git worktree" "${bootstrap}" validate --project test-project --bundle "${work}/sibling-git/bundle.json"
grep -Fq 'outside every Git worktree' "${work}/expected.stderr" || fail "Git worktree rejection diagnostic is missing"

chmod 0644 "${work}/bundle.json"
expect_fail "permissive bundle mode" "${bootstrap}" validate --project test-project --bundle "${work}/bundle.json"
chmod 0600 "${work}/bundle.json"

python3 - "${work}/bundle.json" "${work}/duplicate.json" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(source.replace('{\n  "schema":', '{\n  "schema":"duplicate",\n  "schema":', 1))
PY
chmod 0600 "${work}/duplicate.json"
expect_fail "duplicate JSON key" "${bootstrap}" validate --project test-project --bundle "${work}/duplicate.json"

jq '.secrets.api_tls.data.extra="eA=="' "${work}/bundle.json" > "${work}/extra-key.json"
chmod 0600 "${work}/extra-key.json"
expect_fail "extra data key" "${bootstrap}" validate --project test-project --bundle "${work}/extra-key.json"

# /x== decodes successfully, but its non-zero pad bits make it a non-canonical
# spelling of /w==. The operator envelope must reject ambiguous encodings.
jq '.secrets.api_tls.data["client-ca.pem"]="/x=="' "${work}/bundle.json" > "${work}/noncanonical-base64.json"
chmod 0600 "${work}/noncanonical-base64.json"
expect_fail "non-canonical base64" "${bootstrap}" validate --project test-project --bundle "${work}/noncanonical-base64.json"

jq --rawfile wrong "${work}/controller-client.bundle.pem.b64" \
  '.secrets.kagent_client_tls.data["client-credential-bundle.pem"]=$wrong' \
  "${work}/bundle.json" > "${work}/wrong-san.json"
chmod 0600 "${work}/wrong-san.json"
expect_fail "wrong kagent URI SAN" "${bootstrap}" validate --project test-project --bundle "${work}/wrong-san.json"

jq --rawfile wrong "${work}/kagent-client.bundle.pem.b64" \
  '.secrets.kagent_dev_client_tls.data["client-credential-bundle.pem"]=$wrong' \
  "${work}/bundle.json" > "${work}/wrong-dev-san.json"
chmod 0600 "${work}/wrong-dev-san.json"
expect_fail "wrong kagent dev URI SAN" "${bootstrap}" validate --project test-project --bundle "${work}/wrong-dev-san.json"

jq '.CAs[0].IntermediateCertificatesDER=["bm90LXgteDUwOS1kZXI="]' \
  "${work}/actor-ca.pool.json" > "${work}/actor-ca-intermediate.pool.json"
encode_file "${work}/actor-ca-intermediate.pool.json" "${work}/actor-ca-intermediate.pool.json.b64"
jq --rawfile pool "${work}/actor-ca-intermediate.pool.json.b64" \
  '.secrets.actor_id_ca_pool.data.pool=$pool' \
  "${work}/bundle.json" > "${work}/actor-ca-intermediate.json"
chmod 0600 "${work}/actor-ca-intermediate.json"
expect_fail "unsupported CA intermediate" "${bootstrap}" validate --project test-project --bundle "${work}/actor-ca-intermediate.json"
grep -Fq 'intermediate certificates are not supported' "${work}/expected.stderr" || fail "CA intermediate rejection diagnostic is missing"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${work}/actor-ca-no-sign.key.pem" >/dev/null 2>&1
openssl req -new -x509 -key "${work}/actor-ca-no-sign.key.pem" -sha256 -days 2 \
  -subj '/CN=actor-ca-no-sign' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -out "${work}/actor-ca-no-sign.cert.pem" >/dev/null 2>&1
make_actor_ca_bundle_variant \
  actor-ca-no-sign \
  "${work}/actor-ca-no-sign.key.pem" \
  "${work}/actor-ca-no-sign.cert.pem" \
  "${work}/actor-ca-no-sign.json"
expect_fail "actor CA without keyCertSign" "${bootstrap}" validate --project test-project --bundle "${work}/actor-ca-no-sign.json"
grep -Fq 'does not permit certificate signing' "${work}/expected.stderr" || fail "CA keyCertSign rejection diagnostic is missing"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${work}/actor-ca-future.key.pem" >/dev/null 2>&1
openssl req -new -key "${work}/actor-ca-future.key.pem" -sha256 \
  -subj '/CN=actor-ca-future' \
  -out "${work}/actor-ca-future.csr.pem" >/dev/null 2>&1
mkdir -p "${work}/actor-ca-future-newcerts"
: > "${work}/actor-ca-future.index"
printf '1000\n' > "${work}/actor-ca-future.serial"
cat > "${work}/actor-ca-future.openssl.cnf" <<EOF
[ ca ]
default_ca = actor_ca

[ actor_ca ]
database = ${work}/actor-ca-future.index
new_certs_dir = ${work}/actor-ca-future-newcerts
serial = ${work}/actor-ca-future.serial
private_key = ${work}/actor-identity-ca.key.pem
certificate = ${work}/actor-identity-ca.cert.pem
default_md = sha256
policy = actor_ca_policy
x509_extensions = actor_ca_extensions

[ actor_ca_policy ]
commonName = supplied

[ actor_ca_extensions ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
read -r future_start future_end < <(python3 - <<'PY'
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
print(
    (now + timedelta(days=1)).strftime("%Y%m%d%H%M%SZ"),
    (now + timedelta(days=3)).strftime("%Y%m%d%H%M%SZ"),
)
PY
)
openssl ca -batch -selfsign \
  -keyfile "${work}/actor-ca-future.key.pem" \
  -config "${work}/actor-ca-future.openssl.cnf" \
  -in "${work}/actor-ca-future.csr.pem" \
  -out "${work}/actor-ca-future.cert.pem" \
  -startdate "${future_start}" \
  -enddate "${future_end}" \
  -extensions actor_ca_extensions \
  -notext >/dev/null 2>&1
make_actor_ca_bundle_variant \
  actor-ca-future \
  "${work}/actor-ca-future.key.pem" \
  "${work}/actor-ca-future.cert.pem" \
  "${work}/actor-ca-future.json"
expect_fail "future-dated actor CA" "${bootstrap}" validate --project test-project --bundle "${work}/actor-ca-future.json"
grep -Fq 'certificate is not yet valid' "${work}/expected.stderr" || fail "future-dated CA rejection diagnostic is missing"

mkdir -p "${work}/secret-store" "${work}/kube-store" "${work}/mock-bin"
printf '%s' 'postgresql://substrate:private-test-value@10.0.0.2:5432/substrate?sslmode=require' > "${work}/secret-store/substrate-database-url"
while IFS='|' read -r logical secret_id _ _ source _; do
  [[ "${source}" == "operator-envelope-v1" ]] || continue
  jq -c --arg logical "${logical}" '{schema:"yourown.chat/native-secret-envelope/v1",data:.secrets[$logical].data}' \
    "${work}/bundle.json" > "${work}/secret-store/${secret_id}"
done < <(sed -n '/^source_contract_records()/,/^}/p' "${bootstrap}" | sed -n '/^postgres|/,/^CONTRACT$/p' | sed '$d')

cat > "${work}/mock-bin/gcloud" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
store="${MOCK_SECRET_STORE:?}"
printf '%q ' "$@" >> "${store}/argv.log"
printf '\n' >> "${store}/argv.log"
if [[ "$1 $2" == "secrets describe" ]]; then
  printf 'projects/test-project/secrets/%s\n' "$3"
elif [[ "$1 $2 $3" == "secrets versions list" ]]; then
  secret="$4"
  list_count_file="${store}/versions-list-count"
  list_count=0
  if [[ -f "${list_count_file}" ]]; then read -r list_count < "${list_count_file}"; fi
  list_count="$((list_count + 1))"
  printf '%s\n' "${list_count}" > "${list_count_file}"
  if [[ "${MOCK_SM_VERSION_DRIFT_AT_LIST_COUNT:-}" == "${list_count}" && "${MOCK_SM_VERSION_DRIFT_SECRET:-}" == "${secret}" ]]; then
    case "${MOCK_SM_VERSION_DRIFT_MODE:-}" in
      add) : > "${store}/${secret}.extra-version" ;;
      disable) : > "${store}/${secret}.disabled-version" ;;
      *) exit 13 ;;
    esac
  fi
  if [[ -f "${store}/${secret}" ]]; then
    if [[ -f "${store}/${secret}.extra-version" ]]; then
      printf '[{"name":"projects/test-project/secrets/%s/versions/1","state":"ENABLED"},{"name":"projects/test-project/secrets/%s/versions/2","state":"ENABLED"}]\n' "${secret}" "${secret}"
    elif [[ -f "${store}/${secret}.disabled-version" ]]; then
      printf '[{"name":"projects/test-project/secrets/%s/versions/1","state":"DISABLED"}]\n' "${secret}"
    else
      printf '[{"name":"projects/test-project/secrets/%s/versions/1","state":"ENABLED"}]\n' "${secret}"
    fi
  else
    printf '[]\n'
  fi
elif [[ "$1 $2 $3" == "secrets versions access" ]]; then
  secret=""
  output=""
  for arg in "$@"; do
    case "${arg}" in
      --secret=*) secret="${arg#--secret=}" ;;
      --out-file=*) output="${arg#--out-file=}" ;;
    esac
  done
  if [[ -n "${output}" ]]; then
    cp "${store}/${secret}" "${output}"
  else
    cat "${store}/${secret}"
  fi
elif [[ "$1 $2 $3" == "secrets versions add" ]]; then
  secret="$4"
  input=""
  for arg in "$@"; do
    case "${arg}" in --data-file=*) input="${arg#--data-file=}" ;; esac
  done
  if [[ "${MOCK_FAIL_ADD_SECRET:-}" == "${secret}" ]]; then
    exit 9
  fi
  if [[ "${input}" == '-' ]]; then
    tee "${store}/${secret}" >/dev/null
  else
    cp "${input}" "${store}/${secret}"
  fi
  printf '%s\n' "${secret}" >> "${store}/versions-add.log"
  printf 'projects/test-project/secrets/%s/versions/1\n' "${secret}"
else
  exit 2
fi
MOCK

cat > "${work}/mock-bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
store="${MOCK_KUBE_STORE:?}"
joined=" $* "
printf '%q ' "$@" >> "${store}/argv.log"
printf '\n' >> "${store}/argv.log"
if [[ "${joined}" == *' get namespace '* ]]; then
  printf 'namespace/mock\n'
elif [[ "${joined}" == *' auth can-i create secrets '* ]]; then
  if [[ "${MOCK_DENY_CREATE:-0}" == 1 ]]; then
    printf 'no\n'
  else
    printf 'yes\n'
  fi
elif [[ "${joined}" == *' auth can-i patch secrets '* ]]; then
  if [[ "${MOCK_DENY_PATCH:-0}" == 1 ]]; then
    printf 'no\n'
  else
    printf 'yes\n'
  fi
elif [[ "${joined}" == *' auth can-i get secrets '* ]]; then
  printf 'yes\n'
elif [[ "${joined}" == *' apply '* ]]; then
  input="$(mktemp "${TMPDIR:-/tmp}/mock-kube.XXXXXX")"
  trap 'rm -f -- "${input}"' EXIT
  tee "${input}" >/dev/null
  namespace="$(jq -er '.metadata.namespace' "${input}")"
  name="$(jq -er '.metadata.name' "${input}")"
  if [[ "${MOCK_FAIL_APPLY_SECRET:-}" == "${name}" ]]; then
    exit 10
  fi
  if [[ "${MOCK_SM_POSTGRES_VERSION_ADD_ON_APPLY_SECRET:-}" == "${name}" && ! -e "${store}/postgres-drift-triggered" ]]; then
    : > "${MOCK_SECRET_STORE:?}/substrate-database-url.extra-version"
    : > "${store}/postgres-drift-triggered"
  fi
  destination="${store}/${namespace}__${name}.json"
  if [[ -f "${destination}" ]]; then
    uid="$(jq -er '.metadata.uid' "${destination}")"
    resource_version="$(jq -er '.metadata.resourceVersion' "${destination}")"
    jq -e --arg uid "${uid}" --arg resource_version "${resource_version}" \
      '.metadata.uid == $uid and .metadata.resourceVersion == $resource_version' \
      "${input}" >/dev/null
    next_resource_version="$((resource_version + 1))"
    jq --slurpfile desired "${input}" --arg resource_version "${next_resource_version}" '
      .metadata.labels = ((.metadata.labels // {}) + $desired[0].metadata.labels) |
      .metadata.resourceVersion = $resource_version |
      .type = $desired[0].type |
      .data = $desired[0].data
    ' "${destination}" > "${destination}.next"
    mv -f -- "${destination}.next" "${destination}"
  else
    jq --arg uid "uid-${namespace}-${name}" '
      .metadata.uid = $uid |
      .metadata.resourceVersion = "1" |
      .metadata.annotations = {
        "kubectl.kubernetes.io/last-applied-configuration": "sensitive-last-applied-marker"
      }
    ' "${input}" > "${destination}"
  fi
  printf 'secret/%s\n' "${name}"
elif [[ "${joined}" == *' patch secret '* ]]; then
  input="$(mktemp "${TMPDIR:-/tmp}/mock-kube-patch.XXXXXX")"
  trap 'rm -f -- "${input}"' EXIT
  tee "${input}" >/dev/null
  namespace=""
  name=""
  previous=""
  for arg in "$@"; do
    if [[ "${previous}" == '-n' ]]; then namespace="${arg}"; fi
    if [[ "${previous}" == 'secret' ]]; then name="${arg}"; fi
    previous="${arg}"
  done
  destination="${store}/${namespace}__${name}.json"
  uid="$(jq -er '.[0].value' "${input}")"
  resource_version="$(jq -er '.[1].value' "${input}")"
  jq -e --arg uid "${uid}" --arg resource_version "${resource_version}" \
    '.metadata.uid == $uid and .metadata.resourceVersion == $resource_version' \
    "${destination}" >/dev/null
  next_resource_version="$((resource_version + 1))"
  jq --arg resource_version "${next_resource_version}" '
    del(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]) |
    .metadata.resourceVersion = $resource_version
  ' "${destination}" > "${destination}.next"
  mv -f -- "${destination}.next" "${destination}"
  printf 'secret/%s\n' "${name}"
elif [[ "${joined}" == *' get secret '* ]]; then
  namespace=""
  name=""
  previous=""
  for arg in "$@"; do
    if [[ "${previous}" == '-n' ]]; then namespace="${arg}"; fi
    if [[ "${previous}" == 'secret' ]]; then name="${arg}"; fi
    previous="${arg}"
  done
  destination="${store}/${namespace}__${name}.json"
  get_count_file="${store}/secret-get-count"
  get_count=0
  if [[ -f "${get_count_file}" ]]; then read -r get_count < "${get_count_file}"; fi
  get_count="$((get_count + 1))"
  printf '%s\n' "${get_count}" > "${get_count_file}"
  if [[ "${MOCK_KUBE_DRIFT_AT_GET_COUNT:-}" == "${get_count}" && "${MOCK_KUBE_DRIFT_SECRET:-}" == "${namespace}/${name}" ]]; then
    jq '
      .metadata.resourceVersion = (((.metadata.resourceVersion | tonumber) + 1) | tostring) |
      .data["client-ca.pem"] = .data["server-credential-bundle.pem"]
    ' "${destination}" > "${destination}.next"
    mv -f -- "${destination}.next" "${destination}"
  fi
  cat "${destination}"
else
  exit 2
fi
MOCK
chmod 0755 "${work}/mock-bin/gcloud" "${work}/mock-bin/kubectl"

expect_fail "missing Kubernetes Secret create permission" \
  env PATH="${work}/mock-bin:${PATH}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  MOCK_DENY_CREATE=1 \
  "${bootstrap}" bootstrap --project test-project --context test-context --bundle "${work}/bundle.json"
grep -Fq 'cannot create Secrets' "${work}/expected.stderr" || fail "create permission preflight diagnostic is missing"
[[ ! -e "${work}/secret-store/versions-add.log" ]] || fail "Secret Manager versions were uploaded before create permission preflight"

bootstrap_output="$(
  PATH="${work}/mock-bin:${PATH}" \
  MOCK_SECRET_STORE="${work}/secret-store" \
  MOCK_KUBE_STORE="${work}/kube-store" \
  "${bootstrap}" bootstrap --project test-project --context test-context --bundle "${work}/bundle.json" 2>&1
)"

[[ "$(find "${work}/kube-store" -type f -name '*.json' | wc -l | tr -d ' ')" == 10 ]] || fail "bootstrap did not materialize exactly ten Kubernetes Secrets"
[[ -f "${work}/kube-store/ate-system__actor-id-ca-certs.json" ]] || fail "derived actor-id-ca-certs Secret is missing"
[[ -f "${work}/kube-store/kagent-dev__kagent-dev-ate-client-tls.json" ]] || fail "kagent dev client TLS Secret is missing"
jq -er '.data | keys == ["client-credential-bundle.pem", "server-ca.pem"]' \
  "${work}/kube-store/kagent-dev__kagent-dev-ate-client-tls.json" >/dev/null || fail "kagent dev client TLS keys are wrong"
jq -er '.data | keys == ["ca.crt"]' "${work}/kube-store/ate-system__actor-id-ca-certs.json" >/dev/null || fail "derived actor-id-ca-certs keys are wrong"
jq -er '.data["ca.crt"]' "${work}/kube-store/ate-system__actor-id-ca-certs.json" | openssl base64 -d -A -out "${work}/derived-ca.pem" >/dev/null 2>&1
openssl x509 -in "${work}/derived-ca.pem" -outform DER -out "${work}/derived-ca.der" >/dev/null 2>&1
cmp -s "${work}/derived-ca.der" "${work}/actor-ca.cert.der" || fail "derived ca.crt does not match actor-id-ca-pool CAs[0].RootCertificateDER"
[[ "${bootstrap_output}" != *'private-test-value'* && "${bootstrap_output}" != *'BEGIN PRIVATE KEY'* ]] || fail "bootstrap output leaked secret material"

rg -Fq -- '--data-file="${payload}"' "${bootstrap}" || fail "Secret Manager upload is not file-based"
rg -Fq -- 'apply --server-side --field-manager="${field_manager}" -f -' "${bootstrap}" || fail "Kubernetes sync is not server-side stdin apply"
if rg -n -- '--from-literal|--from-file|terraform (apply|state)|google_secret_manager_secret_version' "${bootstrap}"; then
  fail "bootstrap script can expose bytes in argv or Terraform state"
fi
rg -Fq -- 'native_secret_sync_ready           = false' "${service_inputs}" || fail "bootstrap must not self-attest native Secret readiness"
rg -Fq -- 'kubernetes_name   = "actor-id-ca-certs"' "${components}" || fail "Terraform contract omits the derived Secret"
rg -Fq -- 'expected_derived_secret_contract' "${prerequisites}" || fail "readiness contract omits the derived Secret"

printf 'substrate secret bootstrap tests passed\n'
