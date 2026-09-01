#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
driver="${root_dir}/terraform/app-gcp/modules/kagent-preview-publisher/scripts/publish-artifact-registry.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "${temporary_dir}"' EXIT
workspace="${temporary_dir}/workspace"
mkdir -p \
  "${workspace}/release-inputs" "${workspace}/release" \
  "${temporary_dir}/bin" "${temporary_dir}/indexes" "${temporary_dir}/registry"

fail() {
  printf 'kagent preview publisher tamper test failed: %s\n' "$1" >&2
  exit 1
}

version="0.0.0-external-slot.kap.5"
source_commit="323e584dccbcb3776f045535288f042418e45c1f"
build_id="tamper-test-build"
evaluator_sha="$(printf 'trusted evaluator' | sha256sum | cut -d' ' -f1)"
printf '%s' "${version}" > "${workspace}/kagent-release-version"
printf '%s' "gcp-v${version}" > "${workspace}/kagent-source-tag"
printf '%s' "${source_commit}" > "${workspace}/kagent-source-commit"
printf '%s' "${build_id}" > "${workspace}/kagent-build-id"
printf '%s' '2026-08-31' > "${workspace}/kagent-build-date"

export KAGENT_WORKSPACE_ROOT="${workspace}"
export KAGENT_ARTIFACT_PREFIX="europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent"
export KAGENT_STAGING_PREFIX="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent"
export KAGENT_REGISTRY_HOST="europe-west3-docker.pkg.dev"
export KAGENT_EVIDENCE_BUCKET="yourown-chat-kagent-preview-evidence-europe-west3"
export KAGENT_EXPECTED_BUILD_ID="${build_id}"
export KAGENT_EXPECTED_PROJECT_ID="yourown-chat"
export KAGENT_EXPECTED_SOURCE_COMMIT="${source_commit}"
export KAGENT_EXPECTED_SOURCE_TAG="gcp-v${version}"
export KAGENT_PUBLICATION_DRIVER_SHA256="$(sha256sum "${driver}" | cut -d' ' -f1)"
export KAGENT_SCAN_POLICY_EVALUATOR_SHA256="${evaluator_sha}"

components=(controller ui golang-adk codex-harness)
counter=1
for component in "${components[@]}"; do
  image_digest="sha256:$(printf '%064x' "${counter}")"
  amd64_digest="sha256:$(printf '%064x' "$((counter + 10))")"
  arm64_digest="sha256:$(printf '%064x' "$((counter + 20))")"
  printf '%s=%s\n' "${component}" "${image_digest}" \
    > "${workspace}/release-inputs/image-${component}.txt"
  printf '%s\n' "${image_digest}" > "${temporary_dir}/registry/${component}"
  printf '%s-linux-amd64=%s\n' "${component}" "${amd64_digest}" \
    > "${workspace}/release-inputs/platform-${component}-linux-amd64.txt"
  printf '%s-linux-arm64=%s\n' "${component}" "${arm64_digest}" \
    > "${workspace}/release-inputs/platform-${component}-linux-arm64.txt"
  jq -n --arg amd64 "${amd64_digest}" --arg arm64 "${arm64_digest}" '
    {
      manifests: [
        {digest: $amd64, platform: {os: "linux", architecture: "amd64"}},
        {digest: $arm64, platform: {os: "linux", architecture: "arm64"}}
      ]
    }
  ' > "${temporary_dir}/indexes/${component}.json"
  counter=$((counter + 1))
done
for chart in kagent kagent-crds; do
  chart_digest="sha256:$(printf '%064x' "$((counter + 30))")"
  printf '%s=%s\n' "${chart}" "${chart_digest}" \
    > "${workspace}/release-inputs/chart-${chart}.txt"
  printf '%s\n' "${chart_digest}" > "${temporary_dir}/registry/helm-${chart}"
  counter=$((counter + 1))
done

cat > "${temporary_dir}/bin/docker" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
reference="${!#}"
repository="${reference%@*}"
component="${repository##*/}"
if [[ " $* " == *" --raw "* ]]; then
  cat "${FAKE_INDEX_DIR}/${component}.json"
else
  digest="$(< "${KAGENT_WORKSPACE_ROOT}/release-inputs/image-${component}.txt")"
  printf 'Digest: %s\n' "${digest#${component}=}"
fi
SCRIPT
chmod +x "${temporary_dir}/bin/docker"
cat > "${temporary_dir}/bin/gcloud" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2 $3 ${4:-}" == "artifacts docker images describe" ]]; then
  reference="$5"
  repository="${reference%:*}"
  component="${repository##*/}"
  if [[ "${repository}" == */helm/* ]]; then
    component="helm-${component}"
  fi
  cat "${FAKE_REGISTRY_DIR}/${component}"
elif [[ "$1 $2 $3" == "storage objects describe" ]]; then
  [[ "$4" == "gs://${KAGENT_EVIDENCE_BUCKET}/kagent/${KAGENT_RELEASE_VERSION}/release.lock" ]]
  printf '1\n'
elif [[ "$1 $2" == "storage cat" ]]; then
  [[ "$3" == "gs://${KAGENT_EVIDENCE_BUCKET}/kagent/${KAGENT_RELEASE_VERSION}/release.lock#1" ]]
  cat "${FAKE_REMOTE_LOCK}"
else
  printf 'unexpected fake gcloud invocation: %s\n' "$*" >&2
  exit 1
fi
SCRIPT
chmod +x "${temporary_dir}/bin/gcloud"
export FAKE_INDEX_DIR="${temporary_dir}/indexes"
export FAKE_REGISTRY_DIR="${temporary_dir}/registry"
export FAKE_REMOTE_LOCK="${temporary_dir}/remote-release-lock.json"
export KAGENT_RELEASE_VERSION="${version}"
export PATH="${temporary_dir}/bin:${PATH}"

"${driver}" verify-platform-bindings || fail 'matching index/platform evidence should pass'
controller_platform="${workspace}/release-inputs/platform-controller-linux-amd64.txt"
cp "${controller_platform}" "${controller_platform}.good"
printf 'controller-linux-amd64=sha256:%064d\n' 9 > "${controller_platform}"
if "${driver}" verify-platform-bindings >/dev/null 2>&1; then
  fail 'platform child substitution must fail before promotion'
fi
cp "${controller_platform}.good" "${controller_platform}"

platform_digests='{}'
targets='{}'
: > "${workspace}/release/scan-evidence.sha256"
counter=1
for component in "${components[@]}"; do
  image_digest="$(sed "s/^${component}=//" "${workspace}/release-inputs/image-${component}.txt")"
  amd64_digest="$(sed "s/^${component}-linux-amd64=//" "${workspace}/release-inputs/platform-${component}-linux-amd64.txt")"
  arm64_digest="$(sed "s/^${component}-linux-arm64=//" "${workspace}/release-inputs/platform-${component}-linux-arm64.txt")"
  platform_digests="$(jq -c \
    --arg component "${component}" --arg amd64 "${amd64_digest}" --arg arm64 "${arm64_digest}" \
    '. + {($component): {linux_amd64: $amd64, linux_arm64: $arm64}}' <<<"${platform_digests}")"
  for architecture in amd64 arm64; do
    if [[ "${architecture}" == amd64 ]]; then
      child_digest="${amd64_digest}"
    else
      child_digest="${arm64_digest}"
    fi
    key="${component}-linux-${architecture}"
    evidence_prefix="${workspace}/release/${key}"
    scan_uuid="00000000-0000-4000-8000-$(printf '%012d' "${counter}")"
    scan_id="projects/yourown-chat/locations/europe/scans/${scan_uuid}"
    reference="${KAGENT_STAGING_PREFIX}/${component}@${child_digest}"
    printf '%s\n' "${scan_id}" > "${evidence_prefix}-scan-id.txt"
    printf '[]\n' > "${evidence_prefix}-vulnerabilities.json"
    : > "${evidence_prefix}-severities.txt"
    raw_sha="$(sha256sum "${evidence_prefix}-vulnerabilities.json" | cut -d' ' -f1)"
    jq -n \
      --arg component "${component}" --arg architecture "${architecture}" \
      --arg reference "${reference}" --arg scan_id "${scan_id}" \
      --arg evaluator_sha "${evaluator_sha}" --arg raw_sha "${raw_sha}" '
        {
          schemaVersion: 1,
          policy: {
            id: "kagent-istio-pseudoversion-google-scanner-v1",
            evaluatorSha256: $evaluator_sha
          },
          rawVulnerabilitiesSha256: $raw_sha,
          target: {
            component: $component,
            os: "linux",
            architecture: $architecture,
            imageReference: $reference,
            scanId: $scan_id
          },
          decision: "pass",
          highCriticalFindingCount: 0,
          suppressedHighCriticalFindings: [],
          blockingHighCriticalFindings: []
        }
      ' > "${evidence_prefix}-scan-policy.json"
    scan_id_sha="$(sha256sum "${evidence_prefix}-scan-id.txt" | cut -d' ' -f1)"
    vulnerabilities_sha="$(sha256sum "${evidence_prefix}-vulnerabilities.json" | cut -d' ' -f1)"
    severities_sha="$(sha256sum "${evidence_prefix}-severities.txt" | cut -d' ' -f1)"
    policy_sha="$(sha256sum "${evidence_prefix}-scan-policy.json" | cut -d' ' -f1)"
    for suffix in scan-id.txt vulnerabilities.json severities.txt scan-policy.json; do
      printf '%s  %s\n' \
        "$(sha256sum "${evidence_prefix}-${suffix}" | cut -d' ' -f1)" \
        "${key}-${suffix}" >> "${workspace}/release/scan-evidence.sha256"
    done
    record="$(jq -n \
      --arg component "${component}" --arg architecture "${architecture}" \
      --arg reference "${reference}" --arg scan_id "${scan_id}" \
      --arg evaluator_sha "${evaluator_sha}" --arg scan_id_sha "${scan_id_sha}" \
      --arg vulnerabilities_sha "${vulnerabilities_sha}" --arg severities_sha "${severities_sha}" \
      --arg policy_sha "${policy_sha}" '
        {
          component: $component,
          os: "linux",
          architecture: $architecture,
          imageReference: $reference,
          scanId: $scan_id,
          decision: "pass",
          evaluatorSha256: $evaluator_sha,
          highCriticalFindingCount: 0,
          suppressedHighCriticalFindingCount: 0,
          blockingHighCriticalFindingCount: 0,
          evidence: {
            scanIdSha256: $scan_id_sha,
            vulnerabilitiesSha256: $vulnerabilities_sha,
            severitiesSha256: $severities_sha,
            policyDecisionSha256: $policy_sha
          }
        }
      ')"
    targets="$(jq -c --arg key "${key}" --argjson record "${record}" '. + {($key): $record}' <<<"${targets}")"
    counter=$((counter + 1))
  done
done
printf '%s\n' "${platform_digests}" > "${workspace}/release-inputs/platform-image-digests.json"

scan_manifest_sha="$(sha256sum "${workspace}/release/scan-evidence.sha256" | cut -d' ' -f1)"
jq -n \
  --arg build_id "${build_id}" \
  --arg source_commit "${source_commit}" \
  --arg version "${version}" \
  --arg scan_evidence_sha256 "${scan_manifest_sha}" '
    {
      schemaVersion: 2,
      build_id: $build_id,
      source_commit: $source_commit,
      version: $version,
      scan_evidence_sha256: $scan_evidence_sha256
    }
  ' > "${FAKE_REMOTE_LOCK}"
cp "${FAKE_REMOTE_LOCK}" "${workspace}/release/release-lock.json"
printf '1\n' > "${workspace}/release-inputs/release-lock-generation.txt"
lock_sha="$(sha256sum "${workspace}/release/release-lock.json" | cut -d' ' -f1)"
controller_image="$(sed 's/^controller=//' "${workspace}/release-inputs/image-controller.txt")"
ui_image="$(sed 's/^ui=//' "${workspace}/release-inputs/image-ui.txt")"
golang_image="$(sed 's/^golang-adk=//' "${workspace}/release-inputs/image-golang-adk.txt")"
codex_image="$(sed 's/^codex-harness=//' "${workspace}/release-inputs/image-codex-harness.txt")"
application_chart="$(sed 's/^kagent=//' "${workspace}/release-inputs/chart-kagent.txt")"
crds_chart="$(sed 's/^kagent-crds=//' "${workspace}/release-inputs/chart-kagent-crds.txt")"
jq -n \
  --arg tag "v${version}" --arg source_commit "${source_commit}" \
  --arg prefix "${KAGENT_ARTIFACT_PREFIX}" --arg evaluator_sha "${evaluator_sha}" \
  --arg scan_manifest_sha "${scan_manifest_sha}" --arg lock_sha "${lock_sha}" \
  --arg lock_uri "gs://${KAGENT_EVIDENCE_BUCKET}/kagent/${version}/release.lock#1" \
  --arg controller "${controller_image}" --arg ui "${ui_image}" \
  --arg golang "${golang_image}" --arg codex "${codex_image}" \
  --arg application "${application_chart}" --arg crds "${crds_chart}" \
  --argjson platforms "${platform_digests}" --argjson targets "${targets}" '
    {
      schemaVersion: 3,
      channel: "preview",
      tag: $tag,
      source_repository: "https://github.com/pilprod/kagent",
      source_commit: $source_commit,
      image_refs: {
        controller: ($prefix + "/controller@" + $controller),
        ui: ($prefix + "/ui@" + $ui)
      },
      runtime_images: {
        kagentHarness: ($prefix + "/golang-adk@" + $golang),
        codexHarness: ($prefix + "/codex-harness@" + $codex)
      },
      charts: {
        application: {
          ref: ("oci://" + $prefix + "/helm/kagent@" + $application),
          version: ($tag | ltrimstr("v"))
        },
        crds: {
          ref: ("oci://" + $prefix + "/helm/kagent-crds@" + $crds),
          version: ($tag | ltrimstr("v"))
        }
      },
      platform_image_digests: $platforms,
      security_scans: {
        schema: "yourown.chat/kagent-platform-scan-evidence/v1",
        scanner: "Google Artifact Analysis On-Demand Scanning",
        decision: "pass",
        policy: {
          id: "kagent-istio-pseudoversion-google-scanner-v1",
          evaluatorSha256: $evaluator_sha,
          blockedEffectiveSeverities: ["HIGH", "CRITICAL"]
        },
        evidenceManifestSha256: $scan_manifest_sha,
        releaseLock: {uri: $lock_uri, sha256: $lock_sha},
        targets: $targets
      }
    }
  ' > "${workspace}/release/release-evidence.json"
(cd "${workspace}/release" && sha256sum release-evidence.json > release-evidence.json.sha256)
(cd "${workspace}/release" && sha256sum release-evidence.json scan-evidence.sha256 release-lock.json > SHA256SUMS)

"${driver}" finalize-receipt || fail 'trusted finalizer should accept bound evidence'
"${driver}" prepare-upload || fail 'untampered evidence should remain uploadable'

controller_image_file="${workspace}/release-inputs/image-controller.txt"
cp "${controller_image_file}" "${controller_image_file}.good"
printf 'controller=sha256:%064d\n' 8 > "${controller_image_file}"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'post-assemble image digest substitution must fail final registry validation'
fi
cp "${controller_image_file}.good" "${controller_image_file}"

platform_aggregate="${workspace}/release-inputs/platform-image-digests.json"
cp "${platform_aggregate}" "${platform_aggregate}.good"
jq '.controller.linux_amd64 = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "${platform_aggregate}.good" > "${platform_aggregate}"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'mutable aggregate platform digest substitution must fail canonical child reconstruction'
fi
cp "${platform_aggregate}.good" "${platform_aggregate}"

cp "${workspace}/release/release-lock.json" "${workspace}/release/release-lock.json.good"
printf '{"forged":true}\n' > "${workspace}/release/release-lock.json"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'post-assemble local release lock substitution must fail remote generation validation'
fi
cp "${workspace}/release/release-lock.json.good" "${workspace}/release/release-lock.json"

printf '2\n' > "${workspace}/release-inputs/release-lock-generation.txt"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'mutable release lock generation substitution must fail remote generation validation'
fi
printf '1\n' > "${workspace}/release-inputs/release-lock-generation.txt"

cp "${workspace}/kagent-source-commit" "${workspace}/kagent-source-commit.good"
printf '%040d' 9 > "${workspace}/kagent-source-commit"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'mutable source marker substitution must not replace the Terraform-pinned commit'
fi
cp "${workspace}/kagent-source-commit.good" "${workspace}/kagent-source-commit"

cp "${workspace}/release/release-evidence.json" "${workspace}/release/release-evidence.json.good"
jq '.channel = "tampered"' "${workspace}/release/release-evidence.json.good" \
  > "${workspace}/release/release-evidence.json"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'post-assemble release-evidence rewrite must fail upload validation'
fi
cp "${workspace}/release/release-evidence.json.good" "${workspace}/release/release-evidence.json"

cp "${workspace}/release/release-evidence.json.sha256" "${workspace}/release/release-evidence.json.sha256.good"
cp "${workspace}/release/SHA256SUMS" "${workspace}/release/SHA256SUMS.good"
cp "${workspace}/release-inputs/trusted-release-evidence.sha256" \
  "${workspace}/release-inputs/trusted-release-evidence.sha256.good"
jq '.security_scans.decision = "block"' "${workspace}/release/release-evidence.json.good" \
  > "${workspace}/release/release-evidence.json"
forged_evidence_sha="$(sha256sum "${workspace}/release/release-evidence.json" | cut -d' ' -f1)"
printf '%s  release-evidence.json\n' "${forged_evidence_sha}" \
  > "${workspace}/release/release-evidence.json.sha256"
chmod 0600 "${workspace}/release-inputs/trusted-release-evidence.sha256"
printf '%s\n' "${forged_evidence_sha}" \
  > "${workspace}/release-inputs/trusted-release-evidence.sha256"
awk -v sha="${forged_evidence_sha}" '
  $2 == "release-evidence.json" { $1 = sha }
  { print $1 "  " $2 }
' "${workspace}/release/SHA256SUMS.good" > "${workspace}/release/SHA256SUMS"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'self-consistent but blocking security evidence must fail structural validation'
fi
cp "${workspace}/release/release-evidence.json.good" "${workspace}/release/release-evidence.json"
cp "${workspace}/release/release-evidence.json.sha256.good" "${workspace}/release/release-evidence.json.sha256"
cp "${workspace}/release/SHA256SUMS.good" "${workspace}/release/SHA256SUMS"
cp "${workspace}/release-inputs/trusted-release-evidence.sha256.good" \
  "${workspace}/release-inputs/trusted-release-evidence.sha256"

cp "${workspace}/release/cloud-build-receipt.json" "${workspace}/release/cloud-build-receipt.json.good"
jq '.build_id = "tampered"' "${workspace}/release/cloud-build-receipt.json.good" \
  > "${workspace}/release/cloud-build-receipt.json"
if "${driver}" prepare-upload >/dev/null 2>&1; then
  fail 'post-finalizer receipt rewrite must fail checksum validation'
fi

mutated_driver="${temporary_dir}/mutated-publication-driver.sh"
cp "${driver}" "${mutated_driver}"
printf '\n# tampered after Terraform materialization\n' >> "${mutated_driver}"
chmod +x "${mutated_driver}"
if "${mutated_driver}" prepare-upload >/dev/null 2>&1; then
  fail 'a rewritten finalizer/validator must fail the Terraform-pinned driver hash check'
fi

printf 'kagent preview publisher tamper tests passed\n'
