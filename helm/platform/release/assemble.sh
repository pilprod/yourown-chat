#!/usr/bin/env bash
# Platform release assembler for wrapper-based Cloud Deploy releases.
#
# Reads the service-owned release manifest (helm/release.yaml) of a service
# repository checkout, validates every declared release wrapper against the
# platform contract, vendors the pinned platform profile charts, renders each
# wrapper for every requested Cloud Deploy profile with the typed release
# parameters, runs the platform policy check, and writes:
#
#   <out>/skaffold.yaml            generic Skaffold render configuration
#   <out>/wrappers/<name>/         wrapper chart with vendored dependencies
#   <out>/deploy-parameters        comma-separated Cloud Deploy --deploy-parameters
#   <evidence>/release-evidence.json  chart versions and digests, wrapper
#                                  revision, image digests, overlays, typed
#                                  release parameters, resolved-configuration
#                                  digest per profile
#   <evidence>/rendered/<wrapper>-<profile>.yaml
#
# The assembler never contacts a cluster. It needs bash, helm, python3
# (standard library only) and sha256sum. It is owned by the public platform
# repository and executed by the platform-owned Cloud Build release step;
# service repositories contain only the manifest, wrapper charts and values.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: assemble.sh --repo DIR --out DIR --evidence DIR --chart-registry oci://HOST/PROJECT/REPO
                   --profile NAME=OVERLAY [--profile ...]
                   [--image NAME=REPOSITORY@sha256:DIGEST ...]
                   [--identity KEY=SERVICE_ACCOUNT_EMAIL ...]
                   [--secret-project PROJECT] [--cluster-dns-ip IP]
                   [--source-revision SHA] [--platform-revision SHA]
                   [--allow-file-dependencies] [--skip-dependency-build]

  --profile NAME=OVERLAY   Skaffold profile NAME rendered with values.yaml plus
                           values-OVERLAY.yaml when that overlay exists.
  --image NAME=REF         Immutable digest reference for the image NAME used
                           by a workload in the manifest.
  --identity KEY=EMAIL     Workload Identity e-mail bound to workloads whose
                           manifest `identity` (default: alias) equals KEY.
USAGE
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest_chart="${here}/manifest"
yaml2json_chart="${here}/yaml2json"
policy_check="${here}/policy-check.sh"

repo=""; out=""; evidence=""; chart_registry=""
allow_file=false; skip_dep_build=false
secret_project=""; cluster_dns_ip=""; source_revision=""; platform_revision=""
profiles=(); images=(); identities=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --evidence) evidence="$2"; shift 2 ;;
    --chart-registry) chart_registry="${2%/}"; shift 2 ;;
    --profile) profiles+=("$2"); shift 2 ;;
    --image) images+=("$2"); shift 2 ;;
    --identity) identities+=("$2"); shift 2 ;;
    --secret-project) secret_project="$2"; shift 2 ;;
    --cluster-dns-ip) cluster_dns_ip="$2"; shift 2 ;;
    --source-revision) source_revision="$2"; shift 2 ;;
    --platform-revision) platform_revision="$2"; shift 2 ;;
    --allow-file-dependencies) allow_file=true; shift ;;
    --skip-dependency-build) skip_dep_build=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "assemble: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "assemble: $*" >&2; exit 1; }

[ -n "${repo}" ] || die "--repo is required"
[ -n "${out}" ] || die "--out is required"
[ -n "${evidence}" ] || die "--evidence is required"
[ "${#profiles[@]}" -gt 0 ] || die "at least one --profile NAME=OVERLAY is required"
if [ -z "${chart_registry}" ] && [ "${allow_file}" != "true" ]; then
  die "--chart-registry oci://HOST/PROJECT/REPO is required"
fi
if [ -n "${chart_registry}" ] && ! [[ "${chart_registry}" =~ ^oci://[a-z0-9-]+-docker\.pkg\.dev/[a-z][a-z0-9-]{4,28}[a-z0-9]/[a-z][a-z0-9-]{0,62}$ ]]; then
  die "--chart-registry must be an Artifact Registry OCI path (oci://HOST/PROJECT/REPO)"
fi
for entry in "${profiles[@]}"; do
  [[ "${entry}" =~ ^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?=[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$ ]] || die "--profile must be NAME=OVERLAY in kebab-case: ${entry}"
done
for entry in "${images[@]+"${images[@]}"}"; do
  [[ "${entry}" =~ ^[a-z0-9][a-z0-9._-]*=[a-z0-9-]+-docker\.pkg\.dev/[a-z][a-z0-9-]{4,28}[a-z0-9]/[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$ ]] || die "--image must be NAME=ARTIFACT-REGISTRY-REPOSITORY@sha256:DIGEST: ${entry}"
done
for entry in "${identities[@]+"${identities[@]}"}"; do
  [[ "${entry}" =~ ^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?=[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] || die "--identity must be KEY=EMAIL of a Google service account: ${entry}"
done
[ -z "${secret_project}" ] || [[ "${secret_project}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "--secret-project must be a Google Cloud project id"
[ -z "${cluster_dns_ip}" ] || [[ "${cluster_dns_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--cluster-dns-ip must be an IPv4 address"

manifest_file="${repo}/helm/release.yaml"
[ -f "${manifest_file}" ] || die "release manifest ${manifest_file} not found"

mkdir -p "${out}/wrappers" "${evidence}/rendered"
[ -z "$(ls -A "${out}/wrappers")" ] || die "${out}/wrappers must be empty"

# --- manifest: validate with the manifest chart schema and read as JSON -------
manifest_json="$(helm template release-manifest "${manifest_chart}" -f "${manifest_file}" 2>&1)" \
  || die "release manifest is invalid:
${manifest_json}"
manifest_json="$(printf '%s\n' "${manifest_json}" | grep -Ev '^(#|---)' | sed '/^[[:space:]]*$/d')"
printf '%s\n' "${manifest_json}" > "${evidence}/release-manifest.json"

read_yaml_as_json() {
  local rendered
  rendered="$(helm template yaml2json "${yaml2json_chart}" -f "$1" 2>&1)" || die "cannot read $1 as YAML:
${rendered}"
  printf '%s\n' "${rendered}" | grep -Ev '^(#|---)' | sed '/^[[:space:]]*$/d'
}

# Plan lines: wrapper|name|path|namespace ; workload|wrapper|alias|image|identityKey
plan="$(python3 - "${evidence}/release-manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
seen_wrappers, seen_aliases = set(), set()
for w in m["wrappers"]:
    if w["name"] in seen_wrappers:
        sys.exit(f"duplicate wrapper name {w['name']}")
    seen_wrappers.add(w["name"])
    print(f"wrapper|{w['name']}|{w['path']}|{w['namespace']}")
    for alias, wl in sorted(w["workloads"].items()):
        if alias in seen_aliases:
            sys.exit(f"workload alias {alias} is declared by more than one wrapper; aliases must be unique within a release")
        seen_aliases.add(alias)
        print(f"workload|{w['name']}|{alias}|{wl['image']}|{wl.get('identity', alias)}")
PY
)" || die "release manifest rejected"

lookup() { # lookup KEY in "K=V" entries passed after the key
  local key="$1"; shift
  local entry
  for entry in "$@"; do
    if [ "${entry%%=*}" = "${key}" ]; then printf '%s' "${entry#*=}"; return 0; fi
  done
  return 1
}

deploy_parameters=()
facts="${evidence}/facts.tsv"
: > "${facts}"
skaffold_releases_dir="$(mktemp -d)"
trap 'rm -rf "${skaffold_releases_dir}"' EXIT

while IFS='|' read -r kind name path namespace; do
  [ "${kind}" = "wrapper" ] || continue
  src="${repo}/${path}"
  dest="${out}/wrappers/${name}"
  [ -d "${src}" ] || die "wrapper ${name}: ${src} does not exist"
  [ -f "${src}/Chart.yaml" ] || die "wrapper ${name}: Chart.yaml is required"
  [ -f "${src}/Chart.lock" ] || die "wrapper ${name}: Chart.lock must be committed (pinned platform chart dependencies)"
  [ -f "${src}/values.yaml" ] || die "wrapper ${name}: values.yaml is required"
  [ ! -e "${src}/templates" ] || die "wrapper ${name}: a release wrapper must not contain templates; capabilities come from the platform profiles"
  [ ! -e "${src}/crds" ] || die "wrapper ${name}: a release wrapper must not contain CRDs"
  [ ! -e "${src}/values.schema.json" ] || die "wrapper ${name}: the platform profiles own the values schema; remove values.schema.json"
  while IFS= read -r entry; do
    base="$(basename "${entry}")"
    case "${base}" in
      Chart.yaml|Chart.lock|values.yaml|README.md|.helmignore|charts) ;;
      values-*.yaml) [[ "${base}" =~ ^values-[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?\.yaml$ ]] || die "wrapper ${name}: overlay ${base} must be values-<overlay>.yaml" ;;
      *) die "wrapper ${name}: unexpected file ${base}; a wrapper contains Chart.yaml, Chart.lock, values.yaml, values-<overlay>.yaml, README.md, .helmignore and charts/ only" ;;
    esac
  done < <(find "${src}" -mindepth 1 -maxdepth 1)

  chart_json="$(read_yaml_as_json "${src}/Chart.yaml")"
  printf '%s\n' "${chart_json}" > "${evidence}/${name}-chart.json"
  aliases="$(python3 - "${evidence}/${name}-chart.json" "${chart_registry}" "${allow_file}" "${name}" <<'PY'
import json, re, sys
chart = json.load(open(sys.argv[1]))
registry, allow_file, wrapper = sys.argv[2], sys.argv[3] == "true", sys.argv[4]
if chart.get("apiVersion") != "v2":
    sys.exit(f"wrapper {wrapper}: Chart.yaml apiVersion must be v2")
if chart.get("type", "application") != "application":
    sys.exit(f"wrapper {wrapper}: Chart.yaml type must be application")
if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", str(chart.get("version", ""))):
    sys.exit(f"wrapper {wrapper}: Chart.yaml version must be plain SemVer")
deps = chart.get("dependencies") or []
if not deps:
    sys.exit(f"wrapper {wrapper}: Chart.yaml must pin at least one platform profile dependency")
aliases = []
for d in deps:
    name, version, repo_url, alias = d.get("name", ""), str(d.get("version", "")), d.get("repository", ""), d.get("alias", "")
    if name not in ("platform-service", "platform-worker", "platform-job", "platform-stateful"):
        sys.exit(f"wrapper {wrapper}: dependency {name!r} is not an approved platform profile")
    if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", version):
        sys.exit(f"wrapper {wrapper}: dependency {name} must pin an exact version, got {version!r}")
    if repo_url.startswith("file://"):
        if not allow_file:
            sys.exit(f"wrapper {wrapper}: dependency {name} uses a file:// repository; only the platform OCI registry is allowed")
    elif repo_url.rstrip("/") != registry:
        sys.exit(f"wrapper {wrapper}: dependency {name} repository {repo_url!r} is not the platform chart registry {registry!r}")
    if not re.match(r"^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$", alias):
        sys.exit(f"wrapper {wrapper}: dependency {name} needs a kebab-case alias naming the workload")
    for forbidden in ("condition", "import-values"):
        if forbidden in d:
            sys.exit(f"wrapper {wrapper}: dependency {name} must not use {forbidden}; optional workloads use tags")
    if alias in aliases:
        sys.exit(f"wrapper {wrapper}: alias {alias} is used twice")
    aliases.append(alias)
print("\n".join(aliases))
PY
)" || die "wrapper ${name}: Chart.yaml rejected"

  # Manifest workloads must be exactly the aliases pinned in Chart.yaml.
  manifest_aliases="$(printf '%s\n' "${plan}" | awk -F'|' -v w="${name}" '$1 == "workload" && $2 == w { print $3 }' | sort)"
  chart_aliases="$(printf '%s\n' "${aliases}" | sort)"
  [ "${manifest_aliases}" = "${chart_aliases}" ] || die "wrapper ${name}: manifest workloads [$(printf '%s' "${manifest_aliases}" | tr '\n' ' ')] must equal the Chart.yaml aliases [$(printf '%s' "${chart_aliases}" | tr '\n' ' ')]"

  cp -R "${src}" "${dest}"
  rm -rf "${dest}/charts"
  if [ "${skip_dep_build}" != "true" ]; then
    if ! helm dependency build "${dest}" > "${evidence}/${name}-dependency-build.log" 2>&1; then
      tail -n 5 "${evidence}/${name}-dependency-build.log" >&2 || true
      die "wrapper ${name}: helm dependency build failed (Chart.lock must match Chart.yaml and every chart must be published)"
    fi
    rm -f "${evidence}/${name}-dependency-build.log"
  fi
  for tgz in "${dest}"/charts/*.tgz; do
    [ -f "${tgz}" ] || die "wrapper ${name}: no vendored platform chart under charts/"
    printf 'chart\t%s\t%s\t%s\n' "${name}" "$(basename "${tgz}")" "$(sha256sum "${tgz}" | cut -d' ' -f1)" >> "${facts}"
  done
  printf 'lock\t%s\t%s\n' "${name}" "$(sha256sum "${dest}/Chart.lock" | cut -d' ' -f1)" >> "${facts}"

  # Typed release parameters for every workload of this wrapper.
  wrapper_sets=()
  while IFS='|' read -r wkind wname alias image identity_key; do
    [ "${wkind}" = "workload" ] && [ "${wname}" = "${name}" ] || continue
    image_ref="$(lookup "${image}" "${images[@]+"${images[@]}"}")" || die "wrapper ${name}: no --image provided for ${image} (workload ${alias})"
    wrapper_sets+=("${alias}.image.digest=${image_ref}")
    if identity_email="$(lookup "${identity_key}" "${identities[@]+"${identities[@]}"}")"; then
      wrapper_sets+=("${alias}.identity.googleServiceAccount=${identity_email}")
    fi
    [ -z "${secret_project}" ] || wrapper_sets+=("${alias}.secrets.project=${secret_project}")
    [ -z "${cluster_dns_ip}" ] || wrapper_sets+=("${alias}.network.clusterDNSIP=${cluster_dns_ip}")
    printf 'image\t%s\t%s\t%s\t%s\n' "${name}" "${alias}" "${image}" "${image_ref}" >> "${facts}"
  done <<<"${plan}"
  deploy_parameters+=("${wrapper_sets[@]}")

  # Render and policy-check every profile with the exact release parameters.
  for entry in "${profiles[@]}"; do
    profile="${entry%%=*}"; overlay="${entry#*=}"
    values_args=(-f "${dest}/values.yaml")
    overlay_file="${dest}/values-${overlay}.yaml"
    overlay_digest="none"
    if [ -f "${overlay_file}" ]; then
      values_args+=(-f "${overlay_file}")
      overlay_digest="$(sha256sum "${overlay_file}" | cut -d' ' -f1)"
    fi
    set_args=()
    for kv in "${wrapper_sets[@]}"; do set_args+=(--set-string "${kv}"); done
    rendered="${evidence}/rendered/${name}-${profile}.yaml"
    if ! helm template "${name}" "${dest}" --namespace "${namespace}" "${values_args[@]}" "${set_args[@]}" > "${rendered}" 2> "${rendered}.err"; then
      cat "${rendered}.err" >&2
      die "wrapper ${name}: profile ${profile} does not render against the platform contract"
    fi
    rm -f "${rendered}.err"
    bash "${policy_check}" "${rendered}" || die "wrapper ${name}: profile ${profile} violates the platform policy"
    printf 'render\t%s\t%s\t%s\t%s\t%s\n' "${name}" "${profile}" "${overlay}" "${overlay_digest}" "$(sha256sum "${rendered}" | cut -d' ' -f1)" >> "${facts}"

    {
      printf '          - name: %s\n' "${name}"
      printf '            chartPath: wrappers/%s\n' "${name}"
      printf '            namespace: %s\n' "${namespace}"
      printf '            createNamespace: false\n'
      printf '            skipBuildDependencies: true\n'
      printf '            valuesFiles:\n'
      printf '              - wrappers/%s/values.yaml\n' "${name}"
      [ "${overlay_digest}" = "none" ] || printf '              - wrappers/%s/values-%s.yaml\n' "${name}" "${overlay}"
    } >> "${skaffold_releases_dir}/${profile}"
  done
done <<<"${plan}"

[ "${#deploy_parameters[@]}" -le 50 ] || die "${#deploy_parameters[@]} release parameters exceed the Cloud Deploy limit of 50; split the release manifest"
for kv in "${deploy_parameters[@]}"; do
  key="${kv%%=*}"; value="${kv#*=}"
  [ "${#key}" -le 63 ] || die "release parameter key ${key} exceeds 63 characters"
  [ "${#value}" -le 512 ] || die "release parameter ${key} value exceeds 512 characters"
  [[ "${value}" != *,* ]] || die "release parameter ${key} value must not contain a comma"
done
(IFS=','; printf '%s\n' "${deploy_parameters[*]}") > "${out}/deploy-parameters"

# --- skaffold.yaml ------------------------------------------------------------
{
  cat <<'SKAFFOLD'
# Generated by helm/platform/release/assemble.sh from the service release
# manifest. Cloud Deploy renders the selected profile with `skaffold render`;
# deploy parameters reach the wrapper values as Helm --set arguments.
apiVersion: skaffold/v4beta11
kind: Config
metadata:
  name: platform-wrapper-release
deploy:
  kubectl: {}
profiles:
SKAFFOLD
  for entry in "${profiles[@]}"; do
    profile="${entry%%=*}"
    printf '  - name: %s\n' "${profile}"
    printf '    manifests:\n      helm:\n        releases:\n'
    cat "${skaffold_releases_dir}/${profile}"
  done
} > "${out}/skaffold.yaml"

# --- evidence -----------------------------------------------------------------
python3 - "${facts}" "${evidence}/release-evidence.json" "${out}/deploy-parameters" "${source_revision}" "${platform_revision}" "${chart_registry}" "${profiles[@]}" <<'PY'
import json, sys
facts_path, evidence_path, params_path, source_rev, platform_rev, registry, *profiles = sys.argv[1:]
wrappers = {}
for line in open(facts_path):
    parts = line.rstrip("\n").split("\t")
    kind, wrapper = parts[0], parts[1]
    w = wrappers.setdefault(wrapper, {"platformCharts": [], "chartLockSha256": None, "images": [], "renders": []})
    if kind == "chart":
        w["platformCharts"].append({"artifact": parts[2], "sha256": parts[3]})
    elif kind == "lock":
        w["chartLockSha256"] = parts[2]
    elif kind == "image":
        w["images"].append({"workload": parts[2], "image": parts[3], "reference": parts[4]})
    elif kind == "render":
        w["renders"].append({"profile": parts[2], "overlay": parts[3], "overlaySha256": None if parts[4] == "none" else parts[4], "resolvedConfigurationSha256": parts[5]})
params = open(params_path).read().strip()
evidence = {
    "schema": "platform.yourown.chat/release-evidence/v1",
    "assembler": "helm/platform/release/assemble.sh",
    "platformRevision": platform_rev or None,
    "sourceRevision": source_rev or None,
    "chartRegistry": registry or None,
    "profiles": [{"name": p.split("=")[0], "overlay": p.split("=")[1]} for p in profiles],
    "releaseParameters": sorted(params.split(",")) if params else [],
    "wrappers": wrappers,
}
json.dump(evidence, open(evidence_path, "w"), indent=2, sort_keys=True)
open(evidence_path, "a").write("\n")
PY
rm -f "${facts}"

echo "assembled $(printf '%s\n' "${plan}" | grep -c '^wrapper|') wrapper(s) for profiles: $(printf '%s ' "${profiles[@]}")"
echo "release source: ${out}"
echo "evidence: ${evidence}/release-evidence.json"
