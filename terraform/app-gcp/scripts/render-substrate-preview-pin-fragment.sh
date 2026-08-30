#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

fail() {
  printf 'substrate preview pin fragment: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: render-substrate-preview-pin-fragment.sh \
  substrate-gke-preview.json \
  helm/vendor/substrate/crds.values.yaml \
  helm/vendor/substrate/application.values.yaml

The manifest's adjacent substrate-gke-preview.json.sha256 file is required.
Only an incomplete immutable-pin HCL fragment is written to stdout.
EOF
}

if [[ "$#" -ne 3 ]]; then
  usage
  exit 2
fi

for command_name in git jq ruby; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel 2>/dev/null)" || \
  fail "the generator must run from a Git checkout"
repository_root="$(cd "${repository_root}" && pwd -P)"

canonical_regular_file() {
  local input_path="$1"
  local input_name="$2"
  local input_dir

  [[ -f "${input_path}" ]] || fail "${input_name} must be a regular file"
  [[ ! -L "${input_path}" ]] || fail "${input_name} must not be a symbolic link"
  input_dir="$(cd "$(dirname "${input_path}")" && pwd -P)"
  printf '%s/%s\n' "${input_dir}" "$(basename "${input_path}")"
}

sha256_file() {
  local input_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${input_path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${input_path}" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

require_size_at_most() {
  local input_path="$1"
  local input_name="$2"
  local maximum_bytes="$3"
  local input_bytes

  input_bytes="$(wc -c < "${input_path}" | tr -d '[:space:]')"
  [[ "${input_bytes}" =~ ^[0-9]+$ ]] || fail "could not determine ${input_name} size"
  ((input_bytes <= maximum_bytes)) || fail "${input_name} exceeds ${maximum_bytes} bytes"
}

yaml_to_json() {
  local input_path="$1"

  ruby -ryaml -rjson -e '
    path = ARGV.fetch(0)
    source = File.binread(path)
    stream = Psych.parse_stream(source, filename: path)
    raise "one YAML document is required" unless stream.children.length == 1

    inspect_node = lambda do |node|
      case node
      when Psych::Nodes::Alias
        raise "YAML aliases are not allowed"
      when Psych::Nodes::Mapping
        seen = {}
        node.children.each_slice(2) do |key, value|
          raise "mapping keys must be scalar" unless key.is_a?(Psych::Nodes::Scalar)
          raise "duplicate mapping key" if seen.key?(key.value)
          seen[key.value] = true
          inspect_node.call(value)
        end
      when Psych::Nodes::Sequence
        node.children.each { |child| inspect_node.call(child) }
      else
        Array(node.children).each { |child| inspect_node.call(child) } if node.respond_to?(:children)
      end
    end
    inspect_node.call(stream)

    value = Psych.safe_load(
      source,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false,
      filename: path
    )
    STDOUT.write(JSON.generate(value))
  ' "${input_path}"
}

validate_unique_json() {
  local input_path="$1"

  ruby -rjson -e '
    class UniqueObject < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate object key" if key?(key)
        super
      end
    end

    JSON.parse(
      File.binread(ARGV.fetch(0)),
      object_class: UniqueObject,
      create_additions: false
    )
  ' "${input_path}"
}

manifest="$(canonical_regular_file "$1" manifest)"
crds_values="$(canonical_regular_file "$2" 'CRD values')"
application_values="$(canonical_regular_file "$3" 'application values')"

[[ "$(basename "${manifest}")" == "substrate-gke-preview.json" ]] || \
  fail "manifest must be named substrate-gke-preview.json"
checksum_file="${manifest}.sha256"
checksum_file="$(canonical_regular_file "${checksum_file}" 'manifest checksum')"

for values_file in "${crds_values}" "${application_values}"; do
  [[ "${values_file}" == "${repository_root}"/helm/vendor/substrate/*.values.yaml ]] || \
    fail "values files must be direct children of helm/vendor/substrate"
  [[ "$(basename "${values_file}")" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?\.values\.yaml$ ]] || \
    fail "values filenames must satisfy the vendor bundle path contract"
done
[[ "${crds_values}" != "${application_values}" ]] || fail "CRD and application values must be distinct files"

require_size_at_most "${manifest}" manifest 1048576
require_size_at_most "${checksum_file}" 'manifest checksum' 256
require_size_at_most "${crds_values}" 'CRD values' 5242880
require_size_at_most "${application_values}" 'application values' 5242880

manifest_sha256="$(sha256_file "${manifest}")"
crds_values_sha256="$(sha256_file "${crds_values}")"
application_values_sha256="$(sha256_file "${application_values}")"
if ! printf '%s  substrate-gke-preview.json\n' "${manifest_sha256}" | cmp -s - "${checksum_file}"; then
  fail "manifest does not match its producer checksum"
fi
if ! validate_unique_json "${manifest}" >/dev/null 2>&1; then
  fail "manifest must contain one JSON value with unique object keys"
fi

if ! jq -e '
  def exact_keys($expected):
    type == "object" and ((keys | sort) == ($expected | sort));
  def digest:
    type == "string" and test("^sha256:[0-9a-f]{64}$");
  def image_ref($registry; $component; $digest):
    . == ($registry + "/" + $component + "@" + $digest);
  def chart_ref($registry; $chart; $digest):
    . == ("oci://" + $registry + "/helm/" + $chart + "@" + $digest);
  def immutable_image_ref:
    type == "string" and test("^[^@[:space:]]+/[^@[:space:]]+@sha256:[0-9a-f]{64}$");

  . as $manifest |
  exact_keys([
    "schema_version", "deployment_class", "production_eligible", "source",
    "candidate", "image_digests", "helm_values", "images", "charts"
  ]) and
  .schema_version == "yourown.chat/substrate-gke-preview/v1" and
  .deployment_class == "testbed" and
  .production_eligible == false and

  (.source | exact_keys(["repository", "commit"])) and
  .source.repository == "pilprod/substrate" and
  (.source.commit | type == "string" and test("^[0-9a-f]{40}$")) and

  (.candidate | exact_keys(["image_tag", "chart_version", "image_registry"])) and
  .candidate.image_registry == ("ghcr.io/" + (.source.repository | ascii_downcase)) and
  .candidate.image_tag == ("sha-" + .source.commit) and
  (.candidate.chart_version | type == "string" and test("^0\\.[1-9][0-9]*\\.[1-9][0-9]*$")) and

  (.image_digests | exact_keys(["ateapi", "atecontroller", "ateom-gvisor", "atenet", "releaseVerifier"])) and
  (.image_digests.ateapi | digest) and
  (.image_digests.atecontroller | digest) and
  (.image_digests["ateom-gvisor"] | digest) and
  (.image_digests.atenet | digest) and
  (.image_digests.releaseVerifier | digest) and

  (.helm_values | exact_keys(["image", "images"])) and
  (.helm_values.image | exact_keys(["registry", "digests"])) and
  .helm_values.image.registry == .candidate.image_registry and
  (.helm_values.image.digests | exact_keys(["ateapi", "atecontroller", "atenet"])) and
  .helm_values.image.digests.ateapi == .image_digests.ateapi and
  .helm_values.image.digests.atecontroller == .image_digests.atecontroller and
  .helm_values.image.digests.atenet == .image_digests.atenet and
  (.helm_values.images | exact_keys(["agentgateway"])) and
  (.helm_values.images.agentgateway | immutable_image_ref) and

  (.images | exact_keys(["ateapi", "atecontroller", "ateom-gvisor", "atenet", "agentgateway", "releaseVerifier"])) and
  (.images.ateapi | exact_keys(["ref"])) and
  (.images.atecontroller | exact_keys(["ref"])) and
  (.images["ateom-gvisor"] | exact_keys(["ref"])) and
  (.images.atenet | exact_keys(["ref"])) and
  (.images.agentgateway | exact_keys(["ref"])) and
  (.images.releaseVerifier | exact_keys(["ref"])) and
  (.images.ateapi.ref | image_ref($manifest.candidate.image_registry; "ateapi"; $manifest.image_digests.ateapi)) and
  (.images.atecontroller.ref | image_ref($manifest.candidate.image_registry; "atecontroller"; $manifest.image_digests.atecontroller)) and
  (.images["ateom-gvisor"].ref | image_ref($manifest.candidate.image_registry; "ateom-gvisor"; $manifest.image_digests["ateom-gvisor"])) and
  (.images.atenet.ref | image_ref($manifest.candidate.image_registry; "atenet"; $manifest.image_digests.atenet)) and
  (.images.agentgateway.ref | immutable_image_ref) and
  .images.agentgateway.ref == .helm_values.images.agentgateway and
  (.images.releaseVerifier.ref | immutable_image_ref) and
  (.images.releaseVerifier.ref | image_ref($manifest.candidate.image_registry; "substrate-release-verify"; $manifest.image_digests.releaseVerifier)) and

  (.charts | exact_keys(["crds", "application"])) and
  (.charts.crds | exact_keys(["release_name", "ref", "version", "digest"])) and
  (.charts.application | exact_keys(["release_name", "ref", "version", "digest"])) and
  .charts.crds.release_name == "substrate-crds" and
  .charts.application.release_name == "substrate" and
  .charts.crds.version == .candidate.chart_version and
  .charts.application.version == .candidate.chart_version and
  (.charts.crds.digest | digest) and
  (.charts.application.digest | digest) and
  (.charts.crds.ref | chart_ref($manifest.candidate.image_registry; "substrate-crds"; $manifest.charts.crds.digest)) and
  (.charts.application.ref | chart_ref($manifest.candidate.image_registry; "substrate"; $manifest.charts.application.digest))
' "${manifest}" >/dev/null 2>&1; then
  fail "manifest violates the closed Substrate preview v1 contract"
fi

source_repository="$(jq -er '.source.repository' "${manifest}")"
source_commit="$(jq -er '.source.commit' "${manifest}")"
image_tag="$(jq -er '.candidate.image_tag' "${manifest}")"
image_registry="$(jq -er '.candidate.image_registry' "${manifest}")"
ateapi_digest="$(jq -er '.image_digests.ateapi' "${manifest}")"
atecontroller_digest="$(jq -er '.image_digests.atecontroller' "${manifest}")"
atenet_digest="$(jq -er '.image_digests.atenet' "${manifest}")"
release_verifier_digest="$(jq -er '.image_digests.releaseVerifier' "${manifest}")"
ateom_gvisor_ref="$(jq -er '.images["ateom-gvisor"].ref' "${manifest}")"
agentgateway_ref="$(jq -er '.images.agentgateway.ref' "${manifest}")"
agentgateway_digest="${agentgateway_ref##*@}"
release_verifier_ref="$(jq -er '.images.releaseVerifier.ref' "${manifest}")"
crds_release_name="$(jq -er '.charts.crds.release_name' "${manifest}")"
crds_ref="$(jq -er '.charts.crds.ref' "${manifest}")"
crds_version="$(jq -er '.charts.crds.version' "${manifest}")"
application_release_name="$(jq -er '.charts.application.release_name' "${manifest}")"
application_ref="$(jq -er '.charts.application.ref' "${manifest}")"
application_version="$(jq -er '.charts.application.version' "${manifest}")"
[[ "$(sha256_file "${manifest}")" == "${manifest_sha256}" ]] || \
  fail "manifest changed while it was being validated"

if ! yaml_to_json "${crds_values}" 2>/dev/null | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail "CRD values must be one alias-free YAML mapping with unique scalar keys"
fi

if ! yaml_to_json "${application_values}" 2>/dev/null | jq -e \
  --arg registry "${image_registry}" \
  --arg ateapi "${ateapi_digest}" \
  --arg atecontroller "${atecontroller_digest}" \
  --arg atenet "${atenet_digest}" \
  --arg agentgateway "${agentgateway_ref}" \
  '
    type == "object" and
    (.image | type == "object") and
    (.image | has("registry") and has("digests")) and
    ((.image | keys) - ["digests", "registry", "tag"] | length == 0) and
    .image.registry == $registry and
    ((.image | has("tag") | not) or .image.tag == "") and
    (.image.digests | type == "object") and
    ((.image.digests | keys) == ["ateapi", "atecontroller", "atenet"]) and
    .image.digests.ateapi == $ateapi and
    .image.digests.atecontroller == $atecontroller and
    .image.digests.atenet == $atenet and
    (.images | type == "object" and (keys == ["agentgateway"])) and
    .images.agentgateway == $agentgateway
  ' >/dev/null 2>&1; then
  fail "application values image pins must exactly match manifest.helm_values.image"
fi
[[ "$(sha256_file "${crds_values}")" == "${crds_values_sha256}" ]] || \
  fail "CRD values changed while they were being validated"
[[ "$(sha256_file "${application_values}")" == "${application_values_sha256}" ]] || \
  fail "application values changed while they were being validated"

crds_values_path="${crds_values#"${repository_root}"/}"
application_values_path="${application_values#"${repository_root}"/}"

cat <<EOF
# INCOMPLETE immutable-pin fragment; this is not a vendor_chart_bundles entry.
# manifest_sha256: ${manifest_sha256}
# source_repository: ${source_repository}
# preview_image_tag: ${image_tag}
# external_worker_image_ref: ${ateom_gvisor_ref}
# agentgateway_image_ref: ${agentgateway_ref}
# release_verifier_image_ref: ${release_verifier_ref}
deployment_class    = "testbed"
production_eligible = false
source_commit       = "${source_commit}"

image_digests = {
  ateapi          = "${ateapi_digest}"
  atecontroller   = "${atecontroller_digest}"
  atenet          = "${atenet_digest}"
  agentgateway    = "${agentgateway_digest}"
  releaseVerifier = "${release_verifier_digest}"
}

charts = {
  crds = {
    release_name  = "${crds_release_name}"
    ref           = "${crds_ref}"
    version       = "${crds_version}"
    values_path   = "${crds_values_path}"
    values_sha256 = "${crds_values_sha256}"
  }
  application = {
    release_name  = "${application_release_name}"
    ref           = "${application_ref}"
    version       = "${application_version}"
    values_path   = "${application_values_path}"
    values_sha256 = "${application_values_sha256}"
  }
}
EOF

cat >&2 <<'EOF'
substrate preview pin fragment: generated immutable pins only.
substrate preview pin fragment: a full bundle still requires reviewed fields:
  provisioned, application_enabled, candidate_tag, product_commit,
  supported_agent_runtimes, namespaces, endpoints, external_sources, flows,
  kubernetes_api_egress_from, and database_bindings.
substrate preview pin fragment: the digest-qualified ateom-gvisor WorkerPool
  reference is provenance only and still requires a separately reviewed
  environment resource.
EOF
