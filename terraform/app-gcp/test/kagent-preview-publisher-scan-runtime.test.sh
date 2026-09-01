#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
driver="${root_dir}/terraform/app-gcp/modules/kagent-preview-publisher/scripts/publish-artifact-registry.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "${temporary_dir}"' EXIT
workspace="${temporary_dir}/workspace"
fake_bin="${temporary_dir}/bin"
mkdir -p "${workspace}/release-inputs" "${workspace}/release" "${fake_bin}"
mkdir -p "${workspace}/trusted-bin"

fail() {
  printf 'kagent preview publisher scan runtime test failed: %s\n' "$1" >&2
  exit 1
}

version="0.0.0-external-slot.kap.5"
source_commit="323e584dccbcb3776f045535288f042418e45c1f"
build_id="scan-no-docker-test"
printf '%s' "${version}" > "${workspace}/kagent-release-version"
printf '%s' "gcp-v${version}" > "${workspace}/kagent-source-tag"
printf '%s' "${source_commit}" > "${workspace}/kagent-source-commit"
printf '%s' "${build_id}" > "${workspace}/kagent-build-id"

cat > "${workspace}/evaluate-kagent-scan-vulnerabilities.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: "${KAGENT_JQ_PATH:?KAGENT_JQ_PATH is required}"
"${KAGENT_JQ_PATH}" -n \
  --arg component "$2" \
  --arg architecture "$3" \
  --arg reference "$4" \
  --arg scan_id "$5" \
  '{component: $component, architecture: $architecture, reference: $reference, scanId: $scan_id}' \
  > "$6"
SCRIPT
chmod 0555 "${workspace}/evaluate-kagent-scan-vulnerabilities.sh"
export TEST_JQ_REAL="$(command -v jq)"
cat > "${workspace}/trusted-bin/jq" <<'SCRIPT'
#!/usr/bin/env bash
: "${TEST_JQ_REAL:?TEST_JQ_REAL is required}"
exec "${TEST_JQ_REAL}" "$@"
SCRIPT
chmod 0555 "${workspace}/trusted-bin/jq"

components=(controller ui golang-adk codex-harness)
counter=1
for component in "${components[@]}"; do
  for architecture in amd64 arm64; do
    digest="sha256:$(printf '%064x' "${counter}")"
    printf '%s-linux-%s=%s\n' "${component}" "${architecture}" "${digest}" \
      > "${workspace}/release-inputs/platform-${component}-linux-${architecture}.txt"
    counter=$((counter + 1))
  done
done

cat > "${fake_bin}/docker" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: > "${DOCKER_CALLED_MARKER}"
printf 'Docker must not be called by the Cloud SDK scan action: %s\n' "$*" >&2
exit 97
SCRIPT
chmod 0555 "${fake_bin}/docker"

cat > "${fake_bin}/jq" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: > "${PATH_JQ_CALLED_MARKER}"
printf 'scan action must use only explicit KAGENT_JQ_PATH\n' >&2
exit 98
SCRIPT
chmod 0555 "${fake_bin}/jq"

cat > "${fake_bin}/gcloud" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2 $3 $4" == "artifacts docker images scan" ]]; then
  reference="$5"
  [[ "${reference}" =~ @sha256:[0-9a-f]{64}$ ]]
  suffix="$(printf '%s' "${reference}" | sha256sum | cut -c1-12)"
  printf 'projects/yourown-chat/locations/europe/scans/00000000-0000-4000-8000-%s\n' "${suffix}"
elif [[ "$1 $2 $3 $4" == "artifacts docker images list-vulnerabilities" ]]; then
  printf '[]\n'
else
  printf 'unexpected fake gcloud invocation: %s\n' "$*" >&2
  exit 1
fi
SCRIPT
chmod 0555 "${fake_bin}/gcloud"

export KAGENT_WORKSPACE_ROOT="${workspace}"
export KAGENT_ARTIFACT_PREFIX="europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent"
export KAGENT_STAGING_PREFIX="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent"
export KAGENT_REGISTRY_HOST="europe-west3-docker.pkg.dev"
export KAGENT_PUBLICATION_DRIVER_SHA256="$(sha256sum "${driver}" | cut -d' ' -f1)"
export KAGENT_SCAN_POLICY_EVALUATOR_SHA256="$(sha256sum "${workspace}/evaluate-kagent-scan-vulnerabilities.sh" | cut -d' ' -f1)"
export KAGENT_TRUSTED_JQ_SHA256="$(sha256sum "${workspace}/trusted-bin/jq" | cut -d' ' -f1)"
export DOCKER_CALLED_MARKER="${temporary_dir}/docker-called"
export PATH_JQ_CALLED_MARKER="${temporary_dir}/path-jq-called"
export PATH="${fake_bin}:${PATH}"

"${driver}" scan-images || fail 'Cloud SDK scan action must run successfully without Docker'
[[ ! -e "${DOCKER_CALLED_MARKER}" ]] || fail 'Cloud SDK scan action invoked Docker'
[[ ! -e "${PATH_JQ_CALLED_MARKER}" ]] || fail 'Cloud SDK scan action resolved jq from PATH'

for component in "${components[@]}"; do
  for architecture in amd64 arm64; do
    prefix="${workspace}/release/${component}-linux-${architecture}"
    for suffix in scan-id.txt vulnerabilities.json severities.txt scan-policy.json; do
      [[ -f "${prefix}-${suffix}" ]] || fail "missing ${component}/${architecture} ${suffix} evidence"
    done
  done
done

cp "${workspace}/trusted-bin/jq" "${workspace}/trusted-bin/jq.good"
printf '#!/usr/bin/env bash\nexit 0\n' > "${workspace}/trusted-bin/jq.forged"
chmod 0555 "${workspace}/trusted-bin/jq.forged"
mv -f "${workspace}/trusted-bin/jq.forged" "${workspace}/trusted-bin/jq"
if "${driver}" scan-images >/dev/null 2>&1; then
  fail 'Cloud SDK scan action must reject a substituted JSON parser before use'
fi
mv -f "${workspace}/trusted-bin/jq.good" "${workspace}/trusted-bin/jq"

printf 'kagent preview publisher Cloud SDK scan runtime contract passed\n'
