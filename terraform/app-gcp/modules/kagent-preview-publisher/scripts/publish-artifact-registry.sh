#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s ACTION\n' "$0" >&2
  exit 2
fi

action="$1"
source_root="/workspace/source"
release_inputs="/workspace/release-inputs"
chart_dist="/workspace/chart-dist"
release_dir="/workspace/release"
version="$(< /workspace/kagent-release-version)"
source_tag="$(< /workspace/kagent-source-tag)"
source_commit="$(< /workspace/kagent-source-commit)"
build_id="$(< /workspace/kagent-build-id)"

: "${KAGENT_ARTIFACT_PREFIX:?KAGENT_ARTIFACT_PREFIX is required}"
: "${KAGENT_REGISTRY_HOST:?KAGENT_REGISTRY_HOST is required}"
: "${KAGENT_STAGING_PREFIX:?KAGENT_STAGING_PREFIX is required}"

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
    build_date="$(< /workspace/kagent-build-date)"
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
    done

    jq -n \
      --arg controller_amd64 "$(platform_digest_file controller amd64)" \
      --arg controller_arm64 "$(platform_digest_file controller arm64)" \
      --arg ui_amd64 "$(platform_digest_file ui amd64)" \
      --arg ui_arm64 "$(platform_digest_file ui arm64)" \
      --arg golang_adk_amd64 "$(platform_digest_file golang-adk amd64)" \
      --arg golang_adk_arm64 "$(platform_digest_file golang-adk arm64)" \
      --arg codex_harness_amd64 "$(platform_digest_file codex-harness amd64)" \
      --arg codex_harness_arm64 "$(platform_digest_file codex-harness arm64)" \
      '{
        controller: {linux_amd64: $controller_amd64, linux_arm64: $controller_arm64},
        ui: {linux_amd64: $ui_amd64, linux_arm64: $ui_arm64},
        "golang-adk": {linux_amd64: $golang_adk_amd64, linux_arm64: $golang_adk_arm64},
        "codex-harness": {linux_amd64: $codex_harness_amd64, linux_arm64: $codex_harness_arm64}
      }' > "${release_inputs}/platform-image-digests.json"
    ;;

  acquire-lock)
    : "${KAGENT_EVIDENCE_BUCKET:?KAGENT_EVIDENCE_BUCKET is required}"
    lock_uri="gs://${KAGENT_EVIDENCE_BUCKET}/kagent/${version}/release.lock"
    printf '{"build_id":"%s","source_commit":"%s","version":"%s"}\n' \
      "${build_id}" "${source_commit}" "${version}" |
      gcloud storage cp - "${lock_uri}" --if-generation-match=0
    printf 'acquired immutable release lock: %s\n' "${lock_uri}"
    ;;

  promote-images)
    for component in "${components[@]}"; do
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
    for component in "${components[@]}"; do
      expected="$(digest_file image "${component}")"
      actual="$(gcloud artifacts docker images describe \
        "$(image_repository "${component}"):${version}" \
        --format='value(image_summary.digest)')"
      [[ "${actual}" == "${expected}" ]]
    done
    for chart in "${charts[@]}"; do
      expected="$(digest_file chart "${chart}")"
      actual="$(gcloud artifacts docker images describe \
        "$(chart_repository "${chart}"):${version}" \
        --format='value(image_summary.digest)')"
      [[ "${actual}" == "${expected}" ]]
    done
    ;;

  scan-images)
    mkdir -p "${release_dir}"
    for component in "${components[@]}"; do
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
        gcloud artifacts docker images list-vulnerabilities \
          "${scan}" --format='value(vulnerability.effectiveSeverity)' \
          > "${release_dir}/${evidence_prefix}-severities.txt"
        if grep -Exq 'CRITICAL|HIGH' "${release_dir}/${evidence_prefix}-severities.txt"; then
          printf 'High or Critical vulnerability blocks kagent image %s for linux/%s\n' \
            "${component}" "${architecture}" >&2
          exit 1
        fi
      done
    done
    ;;

  assemble-evidence)
    test ! -e "${release_dir}/release-evidence.json"
    mkdir -p "${release_dir}"
    chart_tree="$(git -C "${source_root}" rev-parse "${source_commit}:helm/kagent")"
    [[ "${chart_tree}" =~ ^[0-9a-f]{40}$ ]]

    controller="$(digest_file image controller)"
    ui="$(digest_file image ui)"
    kagent_harness="$(digest_file image golang-adk)"
    codex_harness="$(digest_file image codex-harness)"
    application="$(digest_file chart kagent)"
    crds="$(digest_file chart kagent-crds)"
    platform_digests="$(< "${release_inputs}/platform-image-digests.json")"

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
      --argjson platform_digests "${platform_digests}" \
      '{
        schemaVersion: 3,
        channel: "preview",
        tag: $source_tag,
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
    for component in "${components[@]}"; do
      for architecture in amd64 arm64; do
        for suffix in scan-id.txt vulnerabilities.json severities.txt; do
          name="${component}-linux-${architecture}-${suffix}"
          [[ -f "${release_dir}/${name}" ]]
          printf '%s  %s\n' \
            "$(sha256sum "${release_dir}/${name}" | cut -d' ' -f1)" \
            "${name}" >> "${release_dir}/SHA256SUMS"
        done
      done
    done
    ;;

  *)
    printf 'unknown kagent Artifact Registry publication action: %s\n' \
      "${action}" >&2
    exit 2
    ;;
esac
