#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s ACTION\n' "$0" >&2
  exit 2
fi

action="$1"
workspace_root="${KAGENT_WORKSPACE_ROOT:-/workspace}"
source_root="${workspace_root}/source"
release_inputs="${workspace_root}/release-inputs"
chart_dist="${workspace_root}/chart-dist"
release_dir="${workspace_root}/release"
version="$(< "${workspace_root}/kagent-release-version")"
source_tag="$(< "${workspace_root}/kagent-source-tag")"
source_commit="$(< "${workspace_root}/kagent-source-commit")"
build_id="$(< "${workspace_root}/kagent-build-id")"
scan_policy_evaluator="${workspace_root}/evaluate-kagent-scan-vulnerabilities.sh"

: "${KAGENT_ARTIFACT_PREFIX:?KAGENT_ARTIFACT_PREFIX is required}"
: "${KAGENT_PUBLICATION_DRIVER_SHA256:?KAGENT_PUBLICATION_DRIVER_SHA256 is required}"
: "${KAGENT_REGISTRY_HOST:?KAGENT_REGISTRY_HOST is required}"
: "${KAGENT_SCAN_POLICY_EVALUATOR_SHA256:?KAGENT_SCAN_POLICY_EVALUATOR_SHA256 is required}"
: "${KAGENT_STAGING_PREFIX:?KAGENT_STAGING_PREFIX is required}"

if [[ "$(sha256sum "$0" | cut -d' ' -f1)" != "${KAGENT_PUBLICATION_DRIVER_SHA256}" ]]; then
  printf 'publication driver integrity check failed\n' >&2
  exit 1
fi

components=(controller ui golang-adk codex-harness)
charts=(kagent kagent-crds)
candidate_tag="${version}-cloudbuild-${build_id}"
buildkit_image="moby/buildkit@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8"

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+\.kap\.[0-9]+$ ]]; then
  printf 'invalid kagent preview version: %s\n' "${version}" >&2
  exit 1
fi
if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'invalid kagent source commit: %s\n' "${source_commit}" >&2
  exit 1
fi
if [[ ! "${source_tag}" =~ ^gcp-v[0-9]+\.[0-9]+\.[0-9]+-external-slot\.kap\.[0-9]+$ ]]; then
  printf 'invalid kagent source tag: %s\n' "${source_tag}" >&2
  exit 1
fi
if [[ ! "${build_id}" =~ ^[0-9A-Za-z.-]+$ ]]; then
  printf 'invalid Cloud Build ID: %s\n' "${build_id}" >&2
  exit 1
fi
image_repository() {
  printf '%s/%s' "${KAGENT_ARTIFACT_PREFIX}" "$1"
}

staging_image_repository() {
  printf '%s/%s' "${KAGENT_STAGING_PREFIX}" "$1"
}

chart_repository() {
  printf '%s/helm/%s' "${KAGENT_ARTIFACT_PREFIX}" "$1"
}

digest_file() {
  local kind="$1"
  local component="$2"
  local path="${release_inputs}/${kind}-${component}.txt"
  local line digest
  line="$(< "${path}")"
  digest="${line#${component}=}"
  if [[ "${line}" == "${digest}" || ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'invalid %s digest evidence for %s\n' "${kind}" "${component}" >&2
    exit 1
  fi
  printf '%s' "${digest}"
}

platform_digest_file() {
  local component="$1"
  local architecture="$2"
  local key="${component}-linux-${architecture}"
  local path="${release_inputs}/platform-${key}.txt"
  local line digest
  line="$(< "${path}")"
  digest="${line#${key}=}"
  if [[ "${line}" == "${digest}" || ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'invalid platform digest evidence for %s\n' "${key}" >&2
    exit 1
  fi
  printf '%s' "${digest}"
}

platform_digests_json() {
  local controller_amd64 controller_arm64 ui_amd64 ui_arm64
  local golang_adk_amd64 golang_adk_arm64 codex_harness_amd64 codex_harness_arm64
  controller_amd64="$(platform_digest_file controller amd64)" || return 1
  controller_arm64="$(platform_digest_file controller arm64)" || return 1
  ui_amd64="$(platform_digest_file ui amd64)" || return 1
  ui_arm64="$(platform_digest_file ui arm64)" || return 1
  golang_adk_amd64="$(platform_digest_file golang-adk amd64)" || return 1
  golang_adk_arm64="$(platform_digest_file golang-adk arm64)" || return 1
  codex_harness_amd64="$(platform_digest_file codex-harness amd64)" || return 1
  codex_harness_arm64="$(platform_digest_file codex-harness arm64)" || return 1
  jq -n \
    --arg controller_amd64 "${controller_amd64}" \
    --arg controller_arm64 "${controller_arm64}" \
    --arg ui_amd64 "${ui_amd64}" \
    --arg ui_arm64 "${ui_arm64}" \
    --arg golang_adk_amd64 "${golang_adk_amd64}" \
    --arg golang_adk_arm64 "${golang_adk_arm64}" \
    --arg codex_harness_amd64 "${codex_harness_amd64}" \
    --arg codex_harness_arm64 "${codex_harness_arm64}" '
      {
        controller: {linux_amd64: $controller_amd64, linux_arm64: $controller_arm64},
        ui: {linux_amd64: $ui_amd64, linux_arm64: $ui_arm64},
        "golang-adk": {linux_amd64: $golang_adk_amd64, linux_arm64: $golang_adk_arm64},
        "codex-harness": {linux_amd64: $codex_harness_amd64, linux_arm64: $codex_harness_arm64}
      }
    ' || return 1
}

inspect_digest() {
  docker buildx imagetools inspect "$1" |
    awk '$1 == "Digest:" { print $2; exit }'
}

assert_tag_absent() {
  local reference="$1"
  local output status
  set +e
  output="$(gcloud artifacts docker images describe \
    "${reference}:${version}" --format='value(image_summary.digest)' 2>&1)"
  status=$?
  set -e
  if [[ ${status} -eq 0 ]]; then
    printf 'refusing to overwrite existing Artifact Registry ref %s:%s (%s)\n' \
      "${reference}" "${version}" "${output}" >&2
    exit 1
  fi
  if ! grep -Eiq 'NOT_FOUND|not found|does not exist' <<<"${output}"; then
    printf 'could not prove Artifact Registry ref is absent: %s:%s\n%s\n' \
      "${reference}" "${version}" "${output}" >&2
    exit 1
  fi
}

file_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

write_scan_evidence_manifest() {
  local manifest="${release_dir}/scan-evidence.sha256"
  local temporary_manifest
  temporary_manifest="$(mktemp "${release_dir}/.scan-evidence.XXXXXX")" || return 1
  : > "${temporary_manifest}" || return 1

  for component in "${components[@]}"; do
    for architecture in amd64 arm64; do
      local evidence_prefix="${component}-linux-${architecture}"
      local policy_file="${release_dir}/${evidence_prefix}-scan-policy.json"
      local scan_id_file="${release_dir}/${evidence_prefix}-scan-id.txt"
      local severity_file="${release_dir}/${evidence_prefix}-severities.txt"
      local scan_id_value reference
      scan_id_value="$(< "${scan_id_file}")" || return 1
      reference="$(staging_image_repository "${component}")@$(platform_digest_file "${component}" "${architecture}")" || return 1
      cmp -s \
        <(jq -r '.[].vulnerability.effectiveSeverity' \
          "${release_dir}/${evidence_prefix}-vulnerabilities.json") \
        "${severity_file}" || return 1

      jq -e \
        --arg component "${component}" \
        --arg architecture "${architecture}" \
        --arg reference "${reference}" \
        --arg scan_id "${scan_id_value}" \
        --arg evaluator_sha256 "${KAGENT_SCAN_POLICY_EVALUATOR_SHA256}" \
        --arg input_sha256 "$(file_sha256 "${release_dir}/${evidence_prefix}-vulnerabilities.json")" '
          .schemaVersion == 1 and
          .policy.id == "kagent-istio-pseudoversion-google-scanner-v1" and
          .policy.evaluatorSha256 == $evaluator_sha256 and
          .rawVulnerabilitiesSha256 == $input_sha256 and
          .decision == "pass" and
          .target == {
            component: $component,
            os: "linux",
            architecture: $architecture,
            imageReference: $reference,
            scanId: $scan_id
          } and
          (.highCriticalFindingCount | type) == "number" and
          .highCriticalFindingCount >= 0 and
          (.highCriticalFindingCount | floor) == .highCriticalFindingCount and
          (.suppressedHighCriticalFindings | type) == "array" and
          (.blockingHighCriticalFindings | type) == "array" and
          .highCriticalFindingCount == (
            (.suppressedHighCriticalFindings | length) +
            (.blockingHighCriticalFindings | length)
          ) and
          (.blockingHighCriticalFindings | length) == 0
        ' "${policy_file}" >/dev/null || return 1

      for suffix in scan-id.txt vulnerabilities.json severities.txt scan-policy.json; do
        local name="${evidence_prefix}-${suffix}"
        local path="${release_dir}/${name}"
        local path_sha256
        [[ -f "${path}" && ! -L "${path}" ]] || return 1
        path_sha256="$(file_sha256 "${path}")" || return 1
        printf '%s  %s\n' "${path_sha256}" "${name}" \
          >> "${temporary_manifest}" || return 1
      done
    done
  done

  mv "${temporary_manifest}" "${manifest}" || return 1
}

scan_evidence_targets_json() {
  local targets='{}'
  for component in "${components[@]}"; do
    for architecture in amd64 arm64; do
      local key="${component}-linux-${architecture}"
      local prefix="${release_dir}/${key}"
      local scan_id_value reference record high_critical_count suppressed_count blocking_count
      scan_id_value="$(< "${prefix}-scan-id.txt")" || return 1
      reference="$(staging_image_repository "${component}")@$(platform_digest_file "${component}" "${architecture}")" || return 1
      high_critical_count="$(jq -er '.highCriticalFindingCount' "${prefix}-scan-policy.json")" || return 1
      suppressed_count="$(jq -er '.suppressedHighCriticalFindings | length' "${prefix}-scan-policy.json")" || return 1
      blocking_count="$(jq -er '.blockingHighCriticalFindings | length' "${prefix}-scan-policy.json")" || return 1
      record="$(jq -n \
        --arg component "${component}" \
        --arg architecture "${architecture}" \
        --arg reference "${reference}" \
        --arg scan_id "${scan_id_value}" \
        --arg scan_id_sha256 "$(file_sha256 "${prefix}-scan-id.txt")" \
        --arg vulnerabilities_sha256 "$(file_sha256 "${prefix}-vulnerabilities.json")" \
        --arg severities_sha256 "$(file_sha256 "${prefix}-severities.txt")" \
        --arg policy_sha256 "$(file_sha256 "${prefix}-scan-policy.json")" \
        --arg evaluator_sha256 "${KAGENT_SCAN_POLICY_EVALUATOR_SHA256}" \
        --argjson high_critical_count "${high_critical_count}" \
        --argjson suppressed_count "${suppressed_count}" \
        --argjson blocking_count "${blocking_count}" '
          {
            component: $component,
            os: "linux",
            architecture: $architecture,
            imageReference: $reference,
            scanId: $scan_id,
            decision: "pass",
            evaluatorSha256: $evaluator_sha256,
            highCriticalFindingCount: $high_critical_count,
            suppressedHighCriticalFindingCount: $suppressed_count,
            blockingHighCriticalFindingCount: $blocking_count,
            evidence: {
              scanIdSha256: $scan_id_sha256,
              vulnerabilitiesSha256: $vulnerabilities_sha256,
              severitiesSha256: $severities_sha256,
              policyDecisionSha256: $policy_sha256
            }
          }
        ')" || return 1
      targets="$(jq -c --arg key "${key}" --argjson record "${record}" \
        '. + {($key): $record}' <<<"${targets}")" || return 1
    done
  done
  printf '%s' "${targets}" || return 1
}

validate_platform_index_binding() {
  local component="$1"
  local manifest_file="$2"

  jq -e '
    [
      .manifests[]
      | select(
          (
            (.platform.os == "linux" and
              (.platform.architecture == "amd64" or .platform.architecture == "arm64"))
            or
            (.platform.os == "unknown" and
              .platform.architecture == "unknown" and
              .annotations["vnd.docker.reference.type"] == "attestation-manifest")
          )
          | not
        )
    ]
    | length == 0
  ' "${manifest_file}" >/dev/null || return 1

  for architecture in amd64 arm64; do
    local count actual expected
    count="$(jq -er \
      --arg architecture "${architecture}" \
      '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture)] | length' \
      "${manifest_file}")" || return 1
    [[ "${count}" == 1 ]] || return 1
    actual="$(jq -er \
      --arg architecture "${architecture}" \
      '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture) | .digest' \
      "${manifest_file}")" || return 1
    expected="$(platform_digest_file "${component}" "${architecture}")" || return 1
    [[ "${actual}" == "${expected}" ]] || return 1
  done
}

verify_remote_platform_binding() {
  local component="$1"
  local expected_index repository reference manifest_file
  expected_index="$(digest_file image "${component}")" || return 1
  repository="$(staging_image_repository "${component}")"
  reference="${repository}@${expected_index}"
  [[ "$(inspect_digest "${reference}")" == "${expected_index}" ]] || return 1
  manifest_file="$(mktemp "${release_inputs}/.remote-index-${component}.XXXXXX")" || return 1
  docker buildx imagetools inspect --raw "${reference}" > "${manifest_file}" || return 1
  validate_platform_index_binding "${component}" "${manifest_file}" || return 1
  rm -f "${manifest_file}" || return 1
}

verify_final_registry_digests() {
  local component chart expected actual
  for component in "${components[@]}"; do
    expected="$(digest_file image "${component}")" || return 1
    actual="$(gcloud artifacts docker images describe \
      "$(image_repository "${component}"):${version}" \
      --format='value(image_summary.digest)')" || return 1
    [[ "${actual}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    [[ "${actual}" == "${expected}" ]] || return 1
  done
  for chart in "${charts[@]}"; do
    expected="$(digest_file chart "${chart}")" || return 1
    actual="$(gcloud artifacts docker images describe \
      "$(chart_repository "${chart}"):${version}" \
      --format='value(image_summary.digest)')" || return 1
    [[ "${actual}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    [[ "${actual}" == "${expected}" ]] || return 1
  done
}

verify_remote_release_lock() {
  local scan_evidence_sha256 lock_base_uri generation remote_lock local_generation
  scan_evidence_sha256="$1"
  lock_base_uri="gs://${KAGENT_EVIDENCE_BUCKET}/kagent/${version}/release.lock"
  generation="$(gcloud storage objects describe \
    "${lock_base_uri}" --format='value(generation)')" || return 1
  [[ "${generation}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -f "${release_inputs}/release-lock-generation.txt" && \
    ! -L "${release_inputs}/release-lock-generation.txt" ]] || return 1
  local_generation="$(< "${release_inputs}/release-lock-generation.txt")" || return 1
  [[ "${local_generation}" == "${generation}" ]] || return 1
  [[ -f "${release_dir}/release-lock.json" && ! -L "${release_dir}/release-lock.json" ]] || return 1
  remote_lock="$(mktemp)" || return 1
  gcloud storage cat "${lock_base_uri}#${generation}" > "${remote_lock}" || return 1
  jq -e \
    --arg build_id "${build_id}" \
    --arg source_commit "${source_commit}" \
    --arg version "${version}" \
    --arg scan_evidence_sha256 "${scan_evidence_sha256}" '
      . == {
        schemaVersion: 2,
        build_id: $build_id,
        source_commit: $source_commit,
        version: $version,
        scan_evidence_sha256: $scan_evidence_sha256
      }
    ' "${remote_lock}" >/dev/null || return 1
  cmp -s "${remote_lock}" "${release_dir}/release-lock.json" || return 1
  verified_release_lock_uri="${lock_base_uri}#${generation}"
  verified_release_lock_sha256="$(file_sha256 "${remote_lock}")" || return 1
  rm -f "${remote_lock}" || return 1
}

validate_release_evidence() {
  local evidence_file="${release_dir}/release-evidence.json"
  local scan_evidence_sha256 release_lock_sha256 lock_uri platform_digests expected_scan_targets
  : "${KAGENT_EXPECTED_BUILD_ID:?KAGENT_EXPECTED_BUILD_ID is required}"
  : "${KAGENT_EXPECTED_PROJECT_ID:?KAGENT_EXPECTED_PROJECT_ID is required}"
  : "${KAGENT_EXPECTED_SOURCE_COMMIT:?KAGENT_EXPECTED_SOURCE_COMMIT is required}"
  : "${KAGENT_EXPECTED_SOURCE_TAG:?KAGENT_EXPECTED_SOURCE_TAG is required}"
  [[ "${KAGENT_EXPECTED_BUILD_ID}" == "${build_id}" ]] || return 1
  [[ "${KAGENT_EXPECTED_PROJECT_ID}" == "yourown-chat" ]] || return 1
  [[ "${KAGENT_EXPECTED_SOURCE_COMMIT}" == "${source_commit}" ]] || return 1
  [[ "${KAGENT_EXPECTED_SOURCE_TAG}" == "${source_tag}" ]] || return 1
  [[ "${KAGENT_EXPECTED_SOURCE_TAG}" == "gcp-v${version}" ]] || return 1
  verify_final_registry_digests || return 1
  write_scan_evidence_manifest || return 1
  (cd "${release_dir}" && sha256sum --check --strict --status scan-evidence.sha256) || return 1
  scan_evidence_sha256="$(file_sha256 "${release_dir}/scan-evidence.sha256")" || return 1
  verify_remote_release_lock "${scan_evidence_sha256}" || return 1
  release_lock_sha256="${verified_release_lock_sha256}"
  lock_uri="${verified_release_lock_uri}"
  platform_digests="$(platform_digests_json)" || return 1
  jq -e --argjson expected "${platform_digests}" \
    '. == $expected' "${release_inputs}/platform-image-digests.json" >/dev/null || return 1
  expected_scan_targets="$(scan_evidence_targets_json)" || return 1

  jq -e \
    --arg source_commit "${source_commit}" \
    --arg tag "v${version}" \
    --arg evaluator_sha256 "${KAGENT_SCAN_POLICY_EVALUATOR_SHA256}" \
    --arg scan_evidence_sha256 "${scan_evidence_sha256}" \
    --arg lock_uri "${lock_uri}" \
    --arg release_lock_sha256 "${release_lock_sha256}" \
    --arg prefix "${KAGENT_ARTIFACT_PREFIX}" \
    --arg controller "$(digest_file image controller)" \
    --arg ui "$(digest_file image ui)" \
    --arg golang_adk "$(digest_file image golang-adk)" \
    --arg codex_harness "$(digest_file image codex-harness)" \
    --arg application "$(digest_file chart kagent)" \
    --arg crds "$(digest_file chart kagent-crds)" \
    --argjson platform_digests "${platform_digests}" \
    --argjson expected_scan_targets "${expected_scan_targets}" '
      def sha256: test("^[0-9a-f]{64}$");
      def digest: test("^sha256:[0-9a-f]{64}$");
      def scan_id:
        test("^projects/yourown-chat/locations/europe/scans/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
      .schemaVersion == 3 and
      .channel == "preview" and
      .tag == $tag and
      .source_repository == "https://github.com/pilprod/kagent" and
      .source_commit == $source_commit and
      .security_scans.schema == "yourown.chat/kagent-platform-scan-evidence/v1" and
      .security_scans.scanner == "Google Artifact Analysis On-Demand Scanning" and
      .security_scans.decision == "pass" and
      .security_scans.policy == {
        id: "kagent-istio-pseudoversion-google-scanner-v1",
        evaluatorSha256: $evaluator_sha256,
        blockedEffectiveSeverities: ["HIGH", "CRITICAL"]
      } and
      .security_scans.evidenceManifestSha256 == $scan_evidence_sha256 and
      .security_scans.releaseLock == {uri: $lock_uri, sha256: $release_lock_sha256} and
      .security_scans.targets == $expected_scan_targets and
      (.security_scans.targets | keys) == [
        "codex-harness-linux-amd64", "codex-harness-linux-arm64",
        "controller-linux-amd64", "controller-linux-arm64",
        "golang-adk-linux-amd64", "golang-adk-linux-arm64",
        "ui-linux-amd64", "ui-linux-arm64"
      ] and
      all(.security_scans.targets | to_entries[];
        .value as $target |
        .key == ($target.component + "-linux-" + $target.architecture) and
        $target.os == "linux" and
        ($target.architecture == "amd64" or $target.architecture == "arm64") and
        $target.decision == "pass" and
        $target.evaluatorSha256 == $evaluator_sha256 and
        ($target.highCriticalFindingCount | type) == "number" and
        ($target.highCriticalFindingCount | floor) == $target.highCriticalFindingCount and
        $target.highCriticalFindingCount >= 0 and
        ($target.suppressedHighCriticalFindingCount | type) == "number" and
        ($target.suppressedHighCriticalFindingCount | floor) == $target.suppressedHighCriticalFindingCount and
        $target.suppressedHighCriticalFindingCount >= 0 and
        $target.blockingHighCriticalFindingCount == 0 and
        $target.highCriticalFindingCount == (
          $target.suppressedHighCriticalFindingCount + $target.blockingHighCriticalFindingCount
        ) and
        ($target.imageReference | test("^europe-west3-docker[.]pkg[.]dev/yourown-chat/kagent-staging/kagent/" + $target.component + "@sha256:[0-9a-f]{64}$")) and
        ($target.scanId | scan_id) and
        ($target.evidence | keys) == ["policyDecisionSha256", "scanIdSha256", "severitiesSha256", "vulnerabilitiesSha256"] and
        all($target.evidence[]; sha256)
      ) and
      .image_refs == {
        controller: ($prefix + "/controller@" + $controller),
        ui: ($prefix + "/ui@" + $ui)
      } and
      .runtime_images == {
        kagentHarness: ($prefix + "/golang-adk@" + $golang_adk),
        codexHarness: ($prefix + "/codex-harness@" + $codex_harness)
      } and
      .charts == {
        application: {
          ref: ("oci://" + $prefix + "/helm/kagent@" + $application),
          version: ($tag | ltrimstr("v"))
        },
        crds: {
          ref: ("oci://" + $prefix + "/helm/kagent-crds@" + $crds),
          version: ($tag | ltrimstr("v"))
        }
      } and
      .platform_image_digests == $platform_digests and
      all(.platform_image_digests[]; all(.[]; digest))
    ' "${evidence_file}" >/dev/null
}

case "${action}" in
  reject-existing)
    for component in "${components[@]}"; do
      assert_tag_absent "$(image_repository "${component}")"
    done
    for chart in "${charts[@]}"; do
      assert_tag_absent "$(chart_repository "${chart}")"
    done
    ;;

  build-images)
    mkdir -p "${release_inputs}"
    builder="kagent-preview-${build_id}"
    build_date="$(< "${workspace_root}/kagent-build-date")"
    [[ "${build_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
    version_package="github.com/kagent-dev/kagent/go/core/internal/version"
    ldflags="-X ${version_package}.Version=${version}"
    ldflags+=" -X ${version_package}.GitCommit=${source_commit}"
    ldflags+=" -X ${version_package}.BuildDate=${build_date}"

    docker buildx create \
      --name "${builder}" \
      --platform linux/amd64,linux/arm64 \
      --driver docker-container \
      --use \
      --driver-opt "image=${buildkit_image}" \
      --driver-opt network=host
    docker buildx inspect "${builder}" --bootstrap

    build_component() {
      local component="$1"
      local dockerfile="$2"
      local context="$3"
      shift 3
      docker buildx build \
        --builder "${builder}" \
        --progress plain \
        --platform linux/amd64,linux/arm64 \
        --push \
        --provenance=mode=max \
        --sbom=true \
        --metadata-file "${release_inputs}/build-${component}.json" \
        --label org.opencontainers.image.source=https://github.com/pilprod/kagent \
        --label org.opencontainers.image.revision="${source_commit}" \
        --build-arg "VERSION=${version}" \
        --build-arg "LDFLAGS=${ldflags}" \
        --build-arg BASE_IMAGE_REGISTRY=cgr.dev \
        --build-arg TOOLS_GO_VERSION=1.27.0 \
        --build-arg TOOLS_NODE_VERSION=24 \
        --tag "$(staging_image_repository "${component}"):${candidate_tag}" \
        "$@" \
        --file "${source_root}/${dockerfile}" \
        "${source_root}/${context}"
    }

    build_component controller go/Dockerfile go \
      --build-arg BUILD_PACKAGE=core/cmd/controller-v2/main.go
    build_component ui ui/Dockerfile ui
    build_component golang-adk go/Dockerfile go \
      --build-arg BUILD_PACKAGE=adk/cmd/main.go
    build_component codex-harness go/harness/codex/Dockerfile go
    ;;

  record-images)
    mkdir -p "${release_inputs}"
    for component in "${components[@]}"; do
      metadata="${release_inputs}/build-${component}.json"
      digest="$(jq -er '."containerimage.digest"' "${metadata}")"
      [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
      printf '%s=%s\n' "${component}" "${digest}" \
        > "${release_inputs}/image-${component}.txt"
    done
    ;;

  verify-candidates)
    for component in "${components[@]}"; do
      expected="$(digest_file image "${component}")"
      staging_repository="$(staging_image_repository "${component}")"
      candidate="${staging_repository}:${candidate_tag}"
      candidate_digest="${staging_repository}@${expected}"
      actual="$(inspect_digest "${candidate}")"
      [[ "${actual}" == "${expected}" ]]
      manifest_file="${release_inputs}/index-${component}.json"
      docker buildx imagetools inspect --raw "${candidate_digest}" > "${manifest_file}"
      grep -Eq '"architecture"[[:space:]]*:[[:space:]]*"amd64"' "${manifest_file}"
      grep -Eq '"architecture"[[:space:]]*:[[:space:]]*"arm64"' "${manifest_file}"
    done
    ;;

  record-platforms)
    for component in "${components[@]}"; do
      manifest_file="${release_inputs}/index-${component}.json"
      [[ -f "${manifest_file}" ]]
      jq -e '
        [
          .manifests[]
          | select(
              (
                (.platform.os == "linux" and
                  (.platform.architecture == "amd64" or .platform.architecture == "arm64"))
                or
                (.platform.os == "unknown" and
                  .platform.architecture == "unknown" and
                  .annotations["vnd.docker.reference.type"] == "attestation-manifest")
              )
              | not
            )
        ]
        | length == 0
      ' "${manifest_file}" >/dev/null
      for architecture in amd64 arm64; do
        count="$(jq -er \
          --arg architecture "${architecture}" \
          '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture)] | length' \
          "${manifest_file}")"
        [[ "${count}" == 1 ]]
        digest="$(jq -er \
          --arg architecture "${architecture}" \
          '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture) | .digest' \
          "${manifest_file}")"
        [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
        key="${component}-linux-${architecture}"
        printf '%s=%s\n' "${key}" "${digest}" \
          > "${release_inputs}/platform-${key}.txt"
      done
      validate_platform_index_binding "${component}" "${manifest_file}"
    done

    platform_digests_json > "${release_inputs}/platform-image-digests.json"
    ;;

  acquire-lock)
    : "${KAGENT_EVIDENCE_BUCKET:?KAGENT_EVIDENCE_BUCKET is required}"
    write_scan_evidence_manifest
    scan_evidence_sha256="$(file_sha256 "${release_dir}/scan-evidence.sha256")"
    lock_uri="gs://${KAGENT_EVIDENCE_BUCKET}/kagent/${version}/release.lock"
    lock_file="${release_inputs}/release-lock.json"
    jq -n \
      --arg build_id "${build_id}" \
      --arg source_commit "${source_commit}" \
      --arg version "${version}" \
      --arg scan_evidence_sha256 "${scan_evidence_sha256}" '
        {
          schemaVersion: 2,
          build_id: $build_id,
          source_commit: $source_commit,
          version: $version,
          scan_evidence_sha256: $scan_evidence_sha256
        }
      ' > "${lock_file}"
    gcloud storage cp "${lock_file}" "${lock_uri}" --if-generation-match=0
    lock_generation="$(gcloud storage objects describe \
      "${lock_uri}" --format='value(generation)')"
    [[ "${lock_generation}" =~ ^[1-9][0-9]*$ ]]
    printf '%s\n' "${lock_generation}" \
      > "${release_inputs}/release-lock-generation.txt"
    printf 'acquired immutable release lock: %s#%s\n' \
      "${lock_uri}" "${lock_generation}"
    ;;

  promote-images)
    for component in "${components[@]}"; do
      verify_remote_platform_binding "${component}"
      expected="$(digest_file image "${component}")"
      repository="$(image_repository "${component}")"
      staging_repository="$(staging_image_repository "${component}")"
      candidate="${staging_repository}:${candidate_tag}"
      final="${repository}:${version}"
      [[ "$(inspect_digest "${candidate}")" == "${expected}" ]]
      docker buildx imagetools create --tag "${final}" "${staging_repository}@${expected}"
      [[ "$(inspect_digest "${final}")" == "${expected}" ]]
    done
    ;;

  verify-platform-bindings)
    for component in "${components[@]}"; do
      verify_remote_platform_binding "${component}"
    done
    ;;

  publish-charts)
    mkdir -p "${release_inputs}"
    gcloud auth print-access-token |
      helm registry login "${KAGENT_REGISTRY_HOST}" \
        --username oauth2accesstoken --password-stdin
    trap 'helm registry logout "${KAGENT_REGISTRY_HOST}" >/dev/null 2>&1 || true' EXIT
    for chart in "${charts[@]}"; do
      archive="${chart_dist}/${chart}-${version}.tgz"
      [[ -f "${archive}" ]]
      output="$(helm push "${archive}" "oci://${KAGENT_ARTIFACT_PREFIX}/helm")"
      digest="$(awk '$1 == "Digest:" { print $2; exit }' <<<"${output}")"
      [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
      printf '%s=%s\n' "${chart}" "${digest}" \
        > "${release_inputs}/chart-${chart}.txt"
      printf '%s\n' "${output}"
    done
    ;;

  verify-finals)
    verify_final_registry_digests
    ;;

  scan-images)
    mkdir -p "${release_dir}"
    [[ -x "${scan_policy_evaluator}" ]]
    if [[ "$(file_sha256 "${scan_policy_evaluator}")" != "${KAGENT_SCAN_POLICY_EVALUATOR_SHA256}" ]]; then
      printf 'scan policy evaluator integrity check failed\n' >&2
      exit 1
    fi
    for component in "${components[@]}"; do
      # Re-read the immutable index from the registry immediately before
      # scanning either child. Stored workspace evidence alone is not trusted.
      verify_remote_platform_binding "${component}"
      for architecture in amd64 arm64; do
        digest="$(platform_digest_file "${component}" "${architecture}")"
        reference="$(staging_image_repository "${component}")@${digest}"
        evidence_prefix="${component}-linux-${architecture}"
        scan="$(gcloud artifacts docker images scan \
          "${reference}" --remote --location=europe \
          --format='value(response.scan)')"
        [[ -n "${scan}" ]]
        printf '%s\n' "${scan}" > "${release_dir}/${evidence_prefix}-scan-id.txt"
        gcloud artifacts docker images list-vulnerabilities \
          "${scan}" --format=json \
          > "${release_dir}/${evidence_prefix}-vulnerabilities.json"
        "${scan_policy_evaluator}" \
          "${release_dir}/${evidence_prefix}-vulnerabilities.json" \
          "${component}" "${architecture}" "${reference}" "${scan}" \
          "${release_dir}/${evidence_prefix}-scan-policy.json"
        jq -r '.[].vulnerability.effectiveSeverity' \
          "${release_dir}/${evidence_prefix}-vulnerabilities.json" \
          > "${release_dir}/${evidence_prefix}-severities.txt"
      done
    done
    ;;

  assemble-evidence)
    test ! -e "${release_dir}/release-evidence.json"
    mkdir -p "${release_dir}"
    : "${KAGENT_EVIDENCE_BUCKET:?KAGENT_EVIDENCE_BUCKET is required}"
    write_scan_evidence_manifest
    scan_evidence_sha256="$(file_sha256 "${release_dir}/scan-evidence.sha256")"
    lock_generation="$(< "${release_inputs}/release-lock-generation.txt")"
    [[ "${lock_generation}" =~ ^[1-9][0-9]*$ ]]
    lock_uri="gs://${KAGENT_EVIDENCE_BUCKET}/kagent/${version}/release.lock#${lock_generation}"
    verified_lock="${release_dir}/release-lock.json"
    test ! -e "${verified_lock}"
    gcloud storage cp "${lock_uri}" "${verified_lock}"
    jq -e \
      --arg build_id "${build_id}" \
      --arg source_commit "${source_commit}" \
      --arg version "${version}" \
      --arg scan_evidence_sha256 "${scan_evidence_sha256}" '
        . == {
          schemaVersion: 2,
          build_id: $build_id,
          source_commit: $source_commit,
          version: $version,
          scan_evidence_sha256: $scan_evidence_sha256
        }
      ' "${verified_lock}" >/dev/null
    release_lock_sha256="$(file_sha256 "${verified_lock}")"
    scan_targets="$(scan_evidence_targets_json)"
    chart_tree="$(git -C "${source_root}" rev-parse "${source_commit}:helm/kagent")"
    [[ "${chart_tree}" =~ ^[0-9a-f]{40}$ ]]

    controller="$(digest_file image controller)"
    ui="$(digest_file image ui)"
    kagent_harness="$(digest_file image golang-adk)"
    codex_harness="$(digest_file image codex-harness)"
    application="$(digest_file chart kagent)"
    crds="$(digest_file chart kagent-crds)"
    platform_digests="$(platform_digests_json)"

    jq -n \
      --arg application "${application}" \
      --arg chart_tree "${chart_tree}" \
      --arg codex_harness "${codex_harness}" \
      --arg controller "${controller}" \
      --arg crds "${crds}" \
      --arg prefix "${KAGENT_ARTIFACT_PREFIX}" \
      --arg source_commit "${source_commit}" \
      --arg source_tag "${source_tag}" \
      --arg ui "${ui}" \
      --arg version "${version}" \
      --arg kagent_harness "${kagent_harness}" \
      --arg buildkit_image "${buildkit_image}" \
      --arg lock_uri "${lock_uri}" \
      --arg release_lock_sha256 "${release_lock_sha256}" \
      --arg scan_evidence_sha256 "${scan_evidence_sha256}" \
      --arg evaluator_sha256 "${KAGENT_SCAN_POLICY_EVALUATOR_SHA256}" \
      --argjson platform_digests "${platform_digests}" \
      --argjson scan_targets "${scan_targets}" \
      '{
        schemaVersion: 3,
        channel: "preview",
        tag: ("v" + $version),
        source_repository: "https://github.com/pilprod/kagent",
        source_commit: $source_commit,
        chart_source: {
          path: "helm/kagent",
          tree: $chart_tree,
          skills_init_removal_commit: "059c01b68584dea113ccdf80f2e356c2d051e02a"
        },
        image_refs: {
          controller: ($prefix + "/controller@" + $controller),
          ui: ($prefix + "/ui@" + $ui)
        },
        runtime_images: {
          kagentHarness: ($prefix + "/golang-adk@" + $kagent_harness),
          codexHarness: ($prefix + "/codex-harness@" + $codex_harness)
        },
        platform_image_digests: $platform_digests,
        build_toolchain: {
          buildkit: $buildkit_image
        },
        security_scans: {
          schema: "yourown.chat/kagent-platform-scan-evidence/v1",
          scanner: "Google Artifact Analysis On-Demand Scanning",
          decision: "pass",
          policy: {
            id: "kagent-istio-pseudoversion-google-scanner-v1",
            evaluatorSha256: $evaluator_sha256,
            blockedEffectiveSeverities: ["HIGH", "CRITICAL"]
          },
          evidenceManifestSha256: $scan_evidence_sha256,
          releaseLock: {
            uri: $lock_uri,
            sha256: $release_lock_sha256
          },
          targets: $scan_targets
        },
        charts: {
          application: {
            ref: ("oci://" + $prefix + "/helm/kagent@" + $application),
            version: $version
          },
          crds: {
            ref: ("oci://" + $prefix + "/helm/kagent-crds@" + $crds),
            version: $version
          }
        }
      }' > "${release_dir}/release-evidence.json"

    evidence_sha="$(sha256sum "${release_dir}/release-evidence.json" | cut -d' ' -f1)"
    printf '%s  release-evidence.json\n' "${evidence_sha}" \
      > "${release_dir}/release-evidence.json.sha256"

    : > "${release_dir}/SHA256SUMS"
    for chart in "${charts[@]}"; do
      archive="${chart}-${version}.tgz"
      cp "${chart_dist}/${archive}" "${release_dir}/${archive}"
      printf '%s  %s\n' \
        "$(sha256sum "${release_dir}/${archive}" | cut -d' ' -f1)" \
        "${archive}" >> "${release_dir}/SHA256SUMS"
    done
    printf '%s  release-evidence.json\n' "${evidence_sha}" \
      >> "${release_dir}/SHA256SUMS"
    ;;

  append-scan-evidence)
    (cd "${release_dir}" && sha256sum --check --status scan-evidence.sha256)
    cat "${release_dir}/scan-evidence.sha256" >> "${release_dir}/SHA256SUMS"
    printf '%s  scan-evidence.sha256\n' \
      "$(file_sha256 "${release_dir}/scan-evidence.sha256")" \
      >> "${release_dir}/SHA256SUMS"
    printf '%s  release-lock.json\n' \
      "$(file_sha256 "${release_dir}/release-lock.json")" \
      >> "${release_dir}/SHA256SUMS"
    ;;

  finalize-receipt)
    : "${KAGENT_EVIDENCE_BUCKET:?KAGENT_EVIDENCE_BUCKET is required}"
    validate_release_evidence || exit 1
    trusted_evidence_sha_file="${release_inputs}/trusted-release-evidence.sha256"
    cloud_build_receipt="${release_dir}/cloud-build-receipt.json"
    test ! -e "${trusted_evidence_sha_file}"
    test ! -e "${cloud_build_receipt}"
    evidence_sha256="$(file_sha256 "${release_dir}/release-evidence.json")"
    printf '%s\n' "${evidence_sha256}" > "${trusted_evidence_sha_file}"
    chmod 0400 "${trusted_evidence_sha_file}"
    jq -n \
      --arg artifact_tag "v${version}" \
      --arg build_id "${build_id}" \
      --arg project_id "yourown-chat" \
      --arg source_commit "${source_commit}" \
      --arg source_tag "${source_tag}" \
      --arg version "${version}" '
        {
          schemaVersion: 2,
          artifact_tag: $artifact_tag,
          builder: "google-cloud-build",
          build_id: $build_id,
          project_id: $project_id,
          source_commit: $source_commit,
          source_tag: $source_tag,
          version: $version
        }
      ' > "${cloud_build_receipt}"
    printf '%s  cloud-build-receipt.json\n' \
      "$(file_sha256 "${cloud_build_receipt}")" \
      >> "${release_dir}/SHA256SUMS"
    (cd "${release_dir}" && sha256sum --check --strict --status SHA256SUMS)
    ;;

  prepare-upload)
    : "${KAGENT_EVIDENCE_BUCKET:?KAGENT_EVIDENCE_BUCKET is required}"
    validate_release_evidence || exit 1
    trusted_evidence_sha_file="${release_inputs}/trusted-release-evidence.sha256"
    trusted_evidence_sha256="$(< "${trusted_evidence_sha_file}")"
    [[ "${trusted_evidence_sha256}" =~ ^[0-9a-f]{64}$ ]]
    [[ "$(file_sha256 "${release_dir}/release-evidence.json")" == "${trusted_evidence_sha256}" ]]
    [[ "$(< "${release_dir}/release-evidence.json.sha256")" == "${trusted_evidence_sha256}  release-evidence.json" ]]
    (cd "${release_dir}" && sha256sum --check --strict --status SHA256SUMS)
    cat "${release_dir}/SHA256SUMS"
    printf '%s  SHA256SUMS\n' "$(file_sha256 "${release_dir}/SHA256SUMS")"
    printf '%s  release-evidence.json.sha256\n' \
      "$(file_sha256 "${release_dir}/release-evidence.json.sha256")"
    ;;

  *)
    printf 'unknown kagent Artifact Registry publication action: %s\n' \
      "${action}" >&2
    exit 2
    ;;
esac
