#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s ACTION\n' "$0" >&2
  exit 2
fi

readonly action="$1"
readonly source_root="/workspace/source"
readonly release_inputs="/workspace/substrate-release-inputs"
readonly chart_dist="/workspace/substrate-chart-dist"
readonly release_dir="/workspace/substrate-release"
readonly release_version="$(< /workspace/substrate-release-version)"
readonly source_tag="$(< /workspace/substrate-source-tag)"
readonly source_commit="$(< /workspace/substrate-source-commit)"
readonly source_tag_object="$(< /workspace/substrate-source-tag-object)"
readonly source_tree="$(< /workspace/substrate-source-tree)"
readonly chart_tree="$(< /workspace/substrate-chart-tree)"
readonly build_id="$(< /workspace/substrate-build-id)"
readonly candidate_tag="${release_version}-cloudbuild-${build_id}"
readonly final_image_tag="v${release_version}"
readonly source_agentgateway_ref="ghcr.io/kagent-dev/substrate/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429"

: "${SUBSTRATE_RELEASE_PREFIX:?SUBSTRATE_RELEASE_PREFIX is required}"
: "${SUBSTRATE_STAGING_PREFIX:?SUBSTRATE_STAGING_PREFIX is required}"
: "${SUBSTRATE_REGISTRY_HOST:?SUBSTRATE_REGISTRY_HOST is required}"
: "${SUBSTRATE_EVIDENCE_BUCKET:?SUBSTRATE_EVIDENCE_BUCKET is required}"

readonly expected_release_prefix="europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate"
readonly expected_staging_prefix="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/substrate"
[[ "${SUBSTRATE_RELEASE_PREFIX}" == "${expected_release_prefix}" ]]
[[ "${SUBSTRATE_STAGING_PREFIX}" == "${expected_staging_prefix}" ]]
[[ "${SUBSTRATE_REGISTRY_HOST}" == "europe-west3-docker.pkg.dev" ]]
[[ "${release_version}" == "0.0.22-private.1" ]]
[[ "${source_tag}" == "v0.0.22" ]]
[[ "${source_commit}" == "e9ed68e587b56df2aa2a7f0267a744598c4d48b4" ]]
[[ "${source_tag_object}" == "00a6a684cea3b3feea67461cf79347332ec759ef" ]]
[[ "${source_tree}" =~ ^[0-9a-f]{40}$ ]]
[[ "${chart_tree}" =~ ^[0-9a-f]{40}$ ]]
[[ "${build_id}" =~ ^[0-9A-Za-z.-]+$ ]]

readonly required_components=(
  agentgateway
  ateapi
  atecontroller
  atenet
)
readonly all_components=("${required_components[@]}")
readonly charts=(substrate substrate-crds)

source_image_ref() {
  case "$1" in
    ateapi)
      printf '%s' 'ghcr.io/pilprod/substrate/ateapi@sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868'
      ;;
    atecontroller)
      printf '%s' 'ghcr.io/pilprod/substrate/atecontroller@sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554'
      ;;
    atenet)
      printf '%s' 'ghcr.io/pilprod/substrate/atenet@sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c'
      ;;
    agentgateway)
      printf '%s' "${source_agentgateway_ref}"
      ;;
    *)
      printf 'unknown source image component: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

image_repository() {
  printf '%s/%s' "${SUBSTRATE_RELEASE_PREFIX}" "$1"
}

staging_image_repository() {
  printf '%s/%s' "${SUBSTRATE_STAGING_PREFIX}" "$1"
}

chart_repository() {
  printf '%s/helm/%s' "${SUBSTRATE_RELEASE_PREFIX}" "$1"
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
  local repository="$1"
  local tag="$2"
  local output status
  set +e
  output="$(gcloud artifacts docker images describe \
    "${repository}:${tag}" --format='value(image_summary.digest)' 2>&1)"
  status=$?
  set -e
  if [[ ${status} -eq 0 ]]; then
    printf 'refusing to overwrite existing Artifact Registry ref %s:%s (%s)\n' \
      "${repository}" "${tag}" "${output}" >&2
    exit 1
  fi
  if ! grep -Eiq 'NOT_FOUND|not found|does not exist' <<<"${output}"; then
    printf 'could not prove Artifact Registry ref is absent: %s:%s\n%s\n' \
      "${repository}" "${tag}" "${output}" >&2
    exit 1
  fi
}

case "${action}" in
  reject-existing)
    for component in "${all_components[@]}"; do
      assert_tag_absent "$(image_repository "${component}")" "${final_image_tag}"
    done
    for chart in "${charts[@]}"; do
      assert_tag_absent "$(chart_repository "${chart}")" "${release_version}"
    done
    ;;

  stage-source-images)
    mkdir -p "${release_inputs}"
    for component in "${all_components[@]}"; do
      source_ref="$(source_image_ref "${component}")"
      source_digest="${source_ref##*@}"
      [[ "${source_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
      repository="$(staging_image_repository "${component}")"
      candidate="${repository}:${candidate_tag}"
      docker buildx imagetools create --tag "${candidate}" "${source_ref}"
      digest="$(inspect_digest "${candidate}")"
      [[ "${digest}" == "${source_digest}" ]]
      printf '%s=%s\n' "${component}" "${digest}" \
        > "${release_inputs}/image-${component}.txt"
    done
    ;;

  verify-candidates)
    for component in "${all_components[@]}"; do
      expected="$(digest_file image "${component}")"
      repository="$(staging_image_repository "${component}")"
      candidate="${repository}:${candidate_tag}"
      [[ "$(inspect_digest "${candidate}")" == "${expected}" ]]
      docker buildx imagetools inspect --raw "${repository}@${expected}" \
        > "${release_inputs}/index-${component}.json"
    done
    ;;

  record-platforms)
    for component in "${all_components[@]}"; do
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

    platform_digests='{}'
    for component in "${all_components[@]}"; do
      for architecture in amd64 arm64; do
        digest="$(platform_digest_file "${component}" "${architecture}")"
        platform_digests="$(jq -c \
          --arg component "${component}" \
          --arg platform "linux_${architecture}" \
          --arg digest "${digest}" \
          '.[$component][$platform] = $digest' <<<"${platform_digests}")"
      done
    done
    jq -S . <<<"${platform_digests}" \
      > "${release_inputs}/platform-image-digests.json"
    jq -e '
      keys == ["agentgateway", "ateapi", "atecontroller", "atenet"] and
      all(.[];
        keys == ["linux_amd64", "linux_arm64"] and
        all(.[]; test("^sha256:[0-9a-f]{64}$"))
      )
    ' "${release_inputs}/platform-image-digests.json" >/dev/null
    ;;

  package-charts)
    : "${HELM_BIN:=/workspace/tools/helm}"
    [[ -x "${HELM_BIN}" ]]
    test ! -e "${chart_dist}"
    mkdir -p "${chart_dist}/source" "${chart_dist}/first" "${chart_dist}/second"
    cp -R "${source_root}/charts/substrate" "${chart_dist}/source/substrate"
    cp -R "${source_root}/charts/substrate-crds" "${chart_dist}/source/substrate-crds"
    values="${chart_dist}/source/substrate/values.yaml"
    source_registry='ghcr.io/kagent-dev/substrate'
    release_registry="${SUBSTRATE_RELEASE_PREFIX}"
    source_gateway="${source_agentgateway_ref}"
    release_gateway="$(image_repository agentgateway)@$(digest_file image agentgateway)"
    [[ "$(grep -Fxc "  registry: ${source_registry}" "${values}")" -eq 1 ]]
    [[ "$(grep -Fxc "  agentgateway: ${source_gateway}" "${values}")" -eq 1 ]]
    sed -i \
      -e "s|^  registry: ${source_registry}$|  registry: ${release_registry}|" \
      -e "s|^  agentgateway: ${source_gateway}$|  agentgateway: ${release_gateway}|" \
      "${values}"
    [[ "$(grep -Fxc "  registry: ${release_registry}" "${values}")" -eq 1 ]]
    [[ "$(grep -Fxc "  agentgateway: ${release_gateway}" "${values}")" -eq 1 ]]
    ! grep -Fq "${source_registry}" "${values}"

    for chart in "${charts[@]}"; do
      metadata="${chart_dist}/source/${chart}/Chart.yaml"
      [[ "$(grep -Ec '^version: ' "${metadata}")" -eq 1 ]]
      [[ "$(grep -Ec '^appVersion: ' "${metadata}")" -eq 1 ]]
      sed -i \
        -e "s|^version: .*$|version: ${release_version}|" \
        -e "s|^appVersion: .*$|appVersion: \"${source_tag}\"|" \
        "${metadata}"
      [[ "$(grep -Fxc "version: ${release_version}" "${metadata}")" -eq 1 ]]
      [[ "$(grep -Fxc "appVersion: \"${source_tag}\"" "${metadata}")" -eq 1 ]]
    done

    "${HELM_BIN}" lint --strict "${chart_dist}/source/substrate-crds"
    "${HELM_BIN}" lint --strict "${chart_dist}/source/substrate" \
      --values "${source_root}/charts/substrate/examples/external-control-plane-only-cloud-sql.values.yaml"

    deterministic_package() {
      local chart="$1"
      local destination="$2"
      python3 - "${chart_dist}/source/${chart}" "${destination}/${chart}-${release_version}.tgz" <<'PY'
import gzip
from pathlib import Path
import sys
import tarfile

source = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
if not source.is_dir() or output.exists():
    raise SystemExit("invalid deterministic chart package input")

paths = [source]
paths.extend(sorted(source.rglob("*"), key=lambda path: path.relative_to(source).as_posix()))
with output.open("xb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for path in paths:
                if path.is_symlink():
                    raise SystemExit(f"chart package refuses symbolic link: {path}")
                relative = path.relative_to(source.parent).as_posix()
                info = archive.gettarinfo(str(path), arcname=relative)
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                info.pax_headers = {}
                if path.is_dir():
                    info.mode = 0o755
                    archive.addfile(info)
                elif path.is_file():
                    info.mode = 0o644
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)
                else:
                    raise SystemExit(f"chart package refuses non-regular path: {path}")
PY
    }

    for destination in first second; do
      for chart in "${charts[@]}"; do
        deterministic_package "${chart}" "${chart_dist}/${destination}"
      done
    done
    for chart in "${charts[@]}"; do
      archive="${chart}-${release_version}.tgz"
      cmp "${chart_dist}/first/${archive}" "${chart_dist}/second/${archive}"
      cp "${chart_dist}/first/${archive}" "${chart_dist}/${archive}"
      packaged_metadata="$("${HELM_BIN}" show chart "${chart_dist}/${archive}")"
      [[ "$(awk '$1 == "version:" { print $2; exit }' <<<"${packaged_metadata}")" == "${release_version}" ]]
      [[ "$(awk '$1 == "appVersion:" { gsub(/\"/, "", $2); print $2; exit }' <<<"${packaged_metadata}")" == "${source_tag}" ]]
    done

    rendered="${chart_dist}/rendered-external.yaml"
    "${HELM_BIN}" template substrate "${chart_dist}/substrate-${release_version}.tgz" \
      --namespace ate-system \
      --values "${source_root}/charts/substrate/examples/external-control-plane-only-cloud-sql.values.yaml" \
      --set-string "image.digests.ateapi=$(digest_file image ateapi)" \
      --set-string "image.digests.atecontroller=$(digest_file image atecontroller)" \
      --set-string "image.digests.atenet=$(digest_file image atenet)" \
      --set-string "images.agentgateway=${release_gateway}" \
      > "${rendered}"
    ! grep -Eq 'ghcr\.io/(pilprod|kagent-dev)/substrate' "${rendered}"
    ;;

  scan-images)
    mkdir -p "${release_dir}"
    for component in "${all_components[@]}"; do
      for architecture in amd64 arm64; do
        digest="$(platform_digest_file "${component}" "${architecture}")"
        reference="$(staging_image_repository "${component}")@${digest}"
        evidence_prefix="${component}-linux-${architecture}"
        scan="$(gcloud artifacts docker images scan \
          "${reference}" --remote --location=europe \
          --format='value(response.scan)')"
        [[ -n "${scan}" ]]
        printf '%s\n' "${reference}" > "${release_dir}/${evidence_prefix}-scan-target.txt"
        printf '%s\n' "${scan}" > "${release_dir}/${evidence_prefix}-scan-id.txt"
        gcloud artifacts docker images list-vulnerabilities \
          "${scan}" --format=json \
          > "${release_dir}/${evidence_prefix}-vulnerabilities.json"
        gcloud artifacts docker images list-vulnerabilities \
          "${scan}" --format='value(vulnerability.effectiveSeverity)' \
          > "${release_dir}/${evidence_prefix}-severities.txt"
        if grep -Exq 'CRITICAL|HIGH' "${release_dir}/${evidence_prefix}-severities.txt"; then
          printf 'High or Critical vulnerability blocks Substrate image %s for linux/%s\n' \
            "${component}" "${architecture}" >&2
          exit 1
        fi
      done
    done
    ;;

  acquire-lock)
    lock_uri="gs://${SUBSTRATE_EVIDENCE_BUCKET}/substrate/${release_version}/release.lock"
    printf '{"build_id":"%s","release_version":"%s","source_commit":"%s","source_tag":"%s"}\n' \
      "${build_id}" "${release_version}" "${source_commit}" "${source_tag}" |
      gcloud storage cp - "${lock_uri}" --if-generation-match=0
    printf 'acquired immutable private Substrate release lock: %s\n' "${lock_uri}"
    ;;

  promote-images)
    for component in "${all_components[@]}"; do
      expected="$(digest_file image "${component}")"
      staging_repository="$(staging_image_repository "${component}")"
      final_repository="$(image_repository "${component}")"
      candidate="${staging_repository}:${candidate_tag}"
      final="${final_repository}:${final_image_tag}"
      [[ "$(inspect_digest "${candidate}")" == "${expected}" ]]
      docker buildx imagetools create --tag "${final}" "${staging_repository}@${expected}"
      [[ "$(inspect_digest "${final}")" == "${expected}" ]]
    done
    ;;

  publish-charts)
    : "${HELM_BIN:=/workspace/tools/helm}"
    [[ -x "${HELM_BIN}" ]]
    gcloud auth print-access-token |
      "${HELM_BIN}" registry login "${SUBSTRATE_REGISTRY_HOST}" \
        --username oauth2accesstoken --password-stdin
    trap '"${HELM_BIN}" registry logout "${SUBSTRATE_REGISTRY_HOST}" >/dev/null 2>&1 || true' EXIT
    mkdir -p "${release_inputs}"
    for chart in "${charts[@]}"; do
      archive="${chart_dist}/${chart}-${release_version}.tgz"
      [[ -f "${archive}" ]]
      output="$("${HELM_BIN}" push "${archive}" "oci://${SUBSTRATE_RELEASE_PREFIX}/helm")"
      digest="$(awk '$1 == "Digest:" { print $2; exit }' <<<"${output}")"
      [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
      printf '%s=%s\n' "${chart}" "${digest}" \
        > "${release_inputs}/chart-${chart}.txt"
      printf '%s\n' "${output}"
    done
    ;;

  verify-finals)
    for component in "${all_components[@]}"; do
      expected="$(digest_file image "${component}")"
      actual="$(gcloud artifacts docker images describe \
        "$(image_repository "${component}"):${final_image_tag}" \
        --format='value(image_summary.digest)')"
      [[ "${actual}" == "${expected}" ]]
    done
    for chart in "${charts[@]}"; do
      expected="$(digest_file chart "${chart}")"
      actual="$(gcloud artifacts docker images describe \
        "$(chart_repository "${chart}"):${release_version}" \
        --format='value(image_summary.digest)')"
      [[ "${actual}" == "${expected}" ]]
    done
    ;;

  assemble-evidence)
    test ! -e "${release_dir}/release-evidence.json"
    mkdir -p "${release_dir}"
    application="$(digest_file chart substrate)"
    crds="$(digest_file chart substrate-crds)"
    platform_digests="$(< "${release_inputs}/platform-image-digests.json")"
    jq -e 'type == "object"' <<<"${platform_digests}" >/dev/null
    source_image_refs='{}'
    for component in "${all_components[@]}"; do
      source_image_refs="$(jq -c \
        --arg component "${component}" \
        --arg ref "$(source_image_ref "${component}")" \
        '.[$component] = $ref' <<<"${source_image_refs}")"
    done
    application_package_sha="sha256:$(sha256sum "${chart_dist}/substrate-${release_version}.tgz" | cut -d' ' -f1)"
    crds_package_sha="sha256:$(sha256sum "${chart_dist}/substrate-crds-${release_version}.tgz" | cut -d' ' -f1)"
    [[ "${application_package_sha}" =~ ^sha256:[0-9a-f]{64}$ ]]
    [[ "${crds_package_sha}" =~ ^sha256:[0-9a-f]{64}$ ]]
    jq -n \
      --arg prefix "${SUBSTRATE_RELEASE_PREFIX}" \
      --arg source_commit "${source_commit}" \
      --arg source_tag "${source_tag}" \
      --arg source_tag_object "${source_tag_object}" \
      --arg source_tree "${source_tree}" \
      --arg chart_tree "${chart_tree}" \
      --arg release_version "${release_version}" \
      --arg ateapi "$(digest_file image ateapi)" \
      --arg atecontroller "$(digest_file image atecontroller)" \
      --arg atenet "$(digest_file image atenet)" \
      --arg agentgateway "$(digest_file image agentgateway)" \
      --arg application "${application}" \
      --arg crds "${crds}" \
      --arg application_package_sha "${application_package_sha}" \
      --arg crds_package_sha "${crds_package_sha}" \
      --argjson platform_digests "${platform_digests}" \
      --argjson source_image_refs "${source_image_refs}" \
      '{
        schema_version: "yourown.chat/substrate-private-gar-release/v1",
        deployment_class: "dev-to-approved-prod",
        production_eligible: true,
        supported_profiles: ["external-control-plane-only"],
        required_components: ["agentgateway", "ateapi", "atecontroller", "atenet"],
        source: {
          repository: "https://github.com/pilprod/substrate",
          commit: $source_commit,
          tag: $source_tag,
          tag_object: $source_tag_object,
          tree: $source_tree,
          chart_tree: $chart_tree
        },
        publication: {
          project_id: "yourown-chat",
          location: "europe-west3",
          registry_visibility: "private",
          build_mode: "copied_exact",
          release_version: $release_version,
          release_prefix: $prefix
        },
        copy_provenance: {
          source_image_refs: $source_image_refs
        },
        images: {
          agentgateway: {ref: ($prefix + "/agentgateway@" + $agentgateway), digest: $agentgateway},
          ateapi: {ref: ($prefix + "/ateapi@" + $ateapi), digest: $ateapi},
          atecontroller: {ref: ($prefix + "/atecontroller@" + $atecontroller), digest: $atecontroller},
          atenet: {ref: ($prefix + "/atenet@" + $atenet), digest: $atenet}
        },
        platform_image_digests: $platform_digests,
        charts: {
          application: {
            release_name: "substrate",
            ref: ("oci://" + $prefix + "/helm/substrate@" + $application),
            version: $release_version,
            digest: $application,
            package_sha256: $application_package_sha
          },
          crds: {
            release_name: "substrate-crds",
            ref: ("oci://" + $prefix + "/helm/substrate-crds@" + $crds),
            version: $release_version,
            digest: $crds,
            package_sha256: $crds_package_sha
          }
        },
        helm_set_values: {
          "image.registry": $prefix,
          "image.digests.ateapi": $ateapi,
          "image.digests.atecontroller": $atecontroller,
          "image.digests.atenet": $atenet,
          "images.agentgateway": ($prefix + "/agentgateway@" + $agentgateway)
        },
        scan_policy: {
          platforms: ["linux/amd64", "linux/arm64"],
          blocked_severities: ["HIGH", "CRITICAL"],
          scanner: "Google Artifact Analysis On-Demand Scanning"
        }
      }' > "${release_dir}/release-evidence.json"

    # RELEASE_EVIDENCE_GUARD_BEGIN
    jq -e \
      --arg release_prefix "${SUBSTRATE_RELEASE_PREFIX}" '
      . as $evidence |
      $evidence.supported_profiles == ["external-control-plane-only"] and
      $evidence.required_components == ["agentgateway", "ateapi", "atecontroller", "atenet"] and
      $evidence.copy_provenance.source_image_refs == {
        agentgateway: "ghcr.io/kagent-dev/substrate/agentgateway@sha256:068028a256bd63c91fd6e85a471269c014747297b0ffa785feaef6967eb0c429",
        ateapi: "ghcr.io/pilprod/substrate/ateapi@sha256:8a4cf985f809cc768e32091e39d45bce5f2e95fe43cd67f01d5e60c7df2ea868",
        atecontroller: "ghcr.io/pilprod/substrate/atecontroller@sha256:0845893ae2ecfd15f580bc410db22c8daae0d6b0388eca67541154a6ec98f554",
        atenet: "ghcr.io/pilprod/substrate/atenet@sha256:01d96092c93fd623dbe051479a76573da551b56be29121b11b760d9067fc8c4c"
      } and
      ($evidence.images | keys) == ["agentgateway", "ateapi", "atecontroller", "atenet"] and
      ($evidence.platform_image_digests | keys) == ["agentgateway", "ateapi", "atecontroller", "atenet"] and
      all($evidence.images | to_entries[];
        (.value | keys) == ["digest", "ref"] and
        (.value.digest | test("^sha256:[0-9a-f]{64}$")) and
        .value.ref == ($release_prefix + "/" + .key + "@" + .value.digest)
      ) and
      all($evidence.required_components[];
        . as $component |
        $evidence.images[$component].digest ==
          ($evidence.copy_provenance.source_image_refs[$component] |
            capture("@(?<digest>sha256:[0-9a-f]{64})$").digest)
      ) and
      all($evidence.platform_image_digests[];
        keys == ["linux_amd64", "linux_arm64"] and
        all(.[]; test("^sha256:[0-9a-f]{64}$"))
      )
    ' "${release_dir}/release-evidence.json" >/dev/null
    # RELEASE_EVIDENCE_GUARD_END

    evidence_sha_hex="$(sha256sum "${release_dir}/release-evidence.json" | cut -d' ' -f1)"
    [[ "${evidence_sha_hex}" =~ ^[0-9a-f]{64}$ ]]
    printf '%s  release-evidence.json\n' "${evidence_sha_hex}" \
      > "${release_dir}/release-evidence.json.sha256"
    jq -n \
      --arg build_id "${build_id}" \
      --arg evidence_sha "sha256:${evidence_sha_hex}" \
      --arg release_version "${release_version}" \
      --arg source_commit "${source_commit}" \
      --arg source_tag "${source_tag}" \
      --arg application_archive "substrate-${release_version}.tgz" \
      --arg application_package_sha "${application_package_sha}" \
      --arg crds_archive "substrate-crds-${release_version}.tgz" \
      --arg crds_package_sha "${crds_package_sha}" \
      '{
        schema_version: "yourown.chat/substrate-private-gar-receipt/v1",
        build: {project_id: "yourown-chat", build_id: $build_id},
        release_version: $release_version,
        source: {commit: $source_commit, tag: $source_tag},
        charts: {
          application: {archive: $application_archive, package_sha256: $application_package_sha},
          crds: {archive: $crds_archive, package_sha256: $crds_package_sha}
        },
        evidence: {path: "release-evidence.json", sha256: $evidence_sha}
      }' > "${release_dir}/release-receipt.json"

    : > "${release_dir}/SHA256SUMS"
    cp "${release_inputs}/platform-image-digests.json" \
      "${release_dir}/platform-image-digests.json"
    for chart in "${charts[@]}"; do
      archive="${chart}-${release_version}.tgz"
      cp "${chart_dist}/${archive}" "${release_dir}/${archive}"
    done
    for component in "${all_components[@]}"; do
      for architecture in amd64 arm64; do
        for suffix in scan-target.txt scan-id.txt vulnerabilities.json severities.txt; do
          name="${component}-linux-${architecture}-${suffix}"
          [[ -f "${release_dir}/${name}" ]]
        done
      done
    done
    while IFS= read -r name; do
      [[ "${name}" == "SHA256SUMS" ]] && continue
      printf '%s  %s\n' \
        "$(sha256sum "${release_dir}/${name}" | cut -d' ' -f1)" \
        "${name}" >> "${release_dir}/SHA256SUMS"
    done < <(find "${release_dir}" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
    ;;

  upload-evidence)
    destination="gs://${SUBSTRATE_EVIDENCE_BUCKET}/substrate/${release_version}"
    while IFS= read -r path; do
      name="${path##*/}"
      gcloud storage cp "${path}" "${destination}/${name}" --if-generation-match=0
    done < <(find "${release_dir}" -maxdepth 1 -type f | LC_ALL=C sort)
    evidence_uri="${destination}/release-evidence.json"
    evidence_generation="$(gcloud storage objects describe \
      "${evidence_uri}" --format='value(generation)')"
    [[ "${evidence_generation}" =~ ^[1-9][0-9]*$ ]]
    evidence_sha="sha256:$(sha256sum "${release_dir}/release-evidence.json" | cut -d' ' -f1)"
    [[ "${evidence_sha}" =~ ^sha256:[0-9a-f]{64}$ ]]
    receipt_uri="${destination}/release-receipt.json"
    receipt_generation="$(gcloud storage objects describe \
      "${receipt_uri}" --format='value(generation)')"
    [[ "${receipt_generation}" =~ ^[1-9][0-9]*$ ]]
    receipt_sha="sha256:$(sha256sum "${release_dir}/release-receipt.json" | cut -d' ' -f1)"
    [[ "${receipt_sha}" =~ ^sha256:[0-9a-f]{64}$ ]]
    printf 'evidence_uri=%s#%s\n' "${evidence_uri}" "${evidence_generation}"
    printf 'evidence_sha256=%s\n' "${evidence_sha}"
    printf 'receipt_uri=%s#%s\n' "${receipt_uri}" "${receipt_generation}"
    printf 'receipt_sha256=%s\n' "${receipt_sha}"
    ;;

  *)
    printf 'unknown private Substrate publication action: %s\n' "${action}" >&2
    exit 2
    ;;
esac
