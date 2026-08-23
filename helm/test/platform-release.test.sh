#!/usr/bin/env bash
# Tests for the platform release assembler (helm/platform/release/assemble.sh)
# against the fixture service repository under
# helm/test/fixtures/platform/service-repo.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

assembler="${repo_root}/helm/platform/release/assemble.sh"
fixture_repo="${fixture_dir}/service-repo"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

api_image="europe-west3-docker.pkg.dev/example-project/docker/yourown-chat-identity-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
migrate_image="europe-west3-docker.pkg.dev/example-project/docker/yourown-chat-identity-migrate@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
common_args=(
  --profile dev=dev --profile prod=prod
  --image "yourown-chat-identity-api=${api_image}"
  --image "yourown-chat-identity-migrate=${migrate_image}"
  --identity identity-api=identity-api@example-project.iam.gserviceaccount.com
  --identity identity-migrate=identity-migrate@example-project.iam.gserviceaccount.com
  --secret-project example-project
  --cluster-dns-ip 10.30.0.10
  --source-revision 0123456789abcdef0123456789abcdef01234567
  --platform-revision fedcba9876543210fedcba9876543210fedcba98
)

# fresh_repo DIR: copies the fixture and points its file:// dependencies at
# this checkout so helm dependency build works from the copied wrapper.
fresh_repo() {
  local dest="$1"
  rm -rf "${dest}"
  cp -R "${fixture_repo}" "${dest}"
  sedi "${dest}/helm/identity/Chart.yaml" "s#file://\.\./\.\./\.\./\.\./\.\./\.\./platform/#file://${repo_root}/helm/platform/#"
  (cd "${dest}/helm/identity" && helm dependency update . >/dev/null 2>&1 && rm -rf charts)
}

# sedi FILE EXPRESSION: portable in-place sed without leaving backup files.
sedi() {
  local file="$1" expression="$2"
  sed -i.bak -e "${expression}" "${file}"
  rm -f "${file}.bak"
}

# run_assembler REPO OUT EVIDENCE [extra args...]
run_assembler() {
  local repo="$1" out="$2" evidence="$3"
  shift 3
  bash "${assembler}" --repo "${repo}" --out "${out}" --evidence "${evidence}" --allow-file-dependencies "${common_args[@]}" "$@"
}

# expect_assemble_fail DESCRIPTION REGEX REPO [extra args...]
expect_assemble_fail() {
  local description="$1" expected="$2" repo="$3"
  shift 3
  local output status
  set +e
  output="$(bash "${assembler}" --repo "${repo}" --out "${work}/fail-out-$RANDOM" --evidence "${work}/fail-ev-$RANDOM" "$@" 2>&1)"
  status=$?
  set -e
  if [ "${status}" -eq 0 ]; then
    echo "FAIL (assembled but must be rejected): ${description}" >&2
    failures=$((failures + 1))
    return 0
  fi
  if ! grep -Eq -- "${expected}" <<<"${output}"; then
    echo "FAIL (rejected for the wrong reason): ${description}" >&2
    echo "  expected: ${expected}" >&2
    echo "  got: $(tail -n 3 <<<"${output}")" >&2
    failures=$((failures + 1))
    return 0
  fi
  echo "ok (rejected): ${description}"
}

# --- happy path -----------------------------------------------------------------
fresh_repo "${work}/repo"
run_assembler "${work}/repo" "${work}/out" "${work}/evidence" >/dev/null

skaffold="${work}/out/skaffold.yaml"
params="${work}/out/deploy-parameters"
evidence_json="${work}/evidence/release-evidence.json"

[ -f "${skaffold}" ] || { echo "FAIL: skaffold.yaml missing" >&2; failures=$((failures + 1)); }
golden "${skaffold}" release-skaffold
assert_contains "${skaffold}" 'apiVersion: skaffold/v4beta11'
assert_contains "${skaffold}" '  - name: dev'
assert_contains "${skaffold}" '  - name: prod'
assert_contains "${skaffold}" 'chartPath: wrappers/identity'
assert_contains "${skaffold}" 'namespace: identity'
assert_contains "${skaffold}" 'skipBuildDependencies: true'
assert_contains "${skaffold}" 'wrappers/identity/values-dev.yaml'
assert_contains "${skaffold}" 'wrappers/identity/values-prod.yaml'
assert_not_contains "${skaffold}" 'rawYaml' "generic config renders Helm wrappers only"
assert_count "${skaffold}" 'chartPath: wrappers/identity' 2

[ -f "${work}/out/wrappers/identity/charts/platform-service-0.1.0.tgz" ] || { echo "FAIL: platform-service chart not vendored" >&2; failures=$((failures + 1)); }
[ -f "${work}/out/wrappers/identity/charts/platform-job-0.1.0.tgz" ] || { echo "FAIL: platform-job chart not vendored" >&2; failures=$((failures + 1)); }
[ -f "${work}/out/wrappers/identity/Chart.lock" ] || { echo "FAIL: Chart.lock missing from release source" >&2; failures=$((failures + 1)); }
[ ! -e "${work}/out/wrappers/identity/templates" ] || { echo "FAIL: templates must not appear in a wrapper" >&2; failures=$((failures + 1)); }

assert_contains "${params}" "identity-api.image.digest=${api_image}"
assert_contains "${params}" "identity-migrate.image.digest=${migrate_image}"
assert_contains "${params}" 'identity-api.identity.googleServiceAccount=identity-api@example-project.iam.gserviceaccount.com'
assert_contains "${params}" 'identity-migrate.identity.googleServiceAccount=identity-migrate@example-project.iam.gserviceaccount.com'
assert_contains "${params}" 'identity-api.secrets.project=example-project'
assert_contains "${params}" 'identity-migrate.network.clusterDNSIP=10.30.0.10'
param_count="$(tr ',' '\n' < "${params}" | grep -c .)"
[ "${param_count}" -eq 8 ] || { echo "FAIL: expected 8 release parameters, found ${param_count}" >&2; failures=$((failures + 1)); }
[ "$(wc -l < "${params}" | tr -d ' ')" -eq 1 ] || { echo "FAIL: deploy-parameters must be a single line" >&2; failures=$((failures + 1)); }

dev_render="${work}/evidence/rendered/identity-dev.yaml"
prod_render="${work}/evidence/rendered/identity-prod.yaml"
[ -f "${dev_render}" ] && [ -f "${prod_render}" ] || { echo "FAIL: rendered evidence missing" >&2; failures=$((failures + 1)); }
assert_contains "${dev_render}" 'priorityClassName: development'
assert_contains "${prod_render}" 'replicas: 2'
assert_contains "${prod_render}" 'kind: PodDisruptionBudget'
assert_not_contains "${dev_render}" 'kind: PodDisruptionBudget' "dev overlay keeps one replica"
assert_contains "${prod_render}" "image: \"${api_image}\""
assert_contains "${prod_render}" 'iam.gke.io/gcp-service-account: "identity-migrate@example-project.iam.gserviceaccount.com"'
assert_contains "${prod_render}" 'resourceName: "projects/example-project/secrets/yourown-chat-identity-database-url/versions/latest"'
assert_contains "${prod_render}" 'cidr: "10.30.0.10/32"'
assert_regex_count() { :; }
bash "${repo_root}/helm/platform/release/policy-check.sh" "${prod_render}" || { echo "FAIL: prod render fails policy" >&2; failures=$((failures + 1)); }

python3 - "${evidence_json}" "${api_image}" <<'PY' || { echo "FAIL: release evidence is incomplete" >&2; failures=$((failures + 1)); }
import json, sys
e = json.load(open(sys.argv[1]))
assert e["schema"] == "platform.yourown.chat/release-evidence/v1"
assert e["sourceRevision"] == "0123456789abcdef0123456789abcdef01234567"
assert e["platformRevision"] == "fedcba9876543210fedcba9876543210fedcba98"
assert [p["name"] for p in e["profiles"]] == ["dev", "prod"]
assert len(e["releaseParameters"]) == 8
w = e["wrappers"]["identity"]
assert {c["artifact"] for c in w["platformCharts"]} == {"platform-service-0.1.0.tgz", "platform-job-0.1.0.tgz"}
assert all(len(c["sha256"]) == 64 for c in w["platformCharts"])
assert len(w["chartLockSha256"]) == 64
assert {i["workload"]: i["reference"] for i in w["images"]}["identity-api"] == sys.argv[2]
renders = {r["profile"]: r for r in w["renders"]}
assert renders["dev"]["overlay"] == "dev" and renders["dev"]["overlaySha256"]
assert renders["prod"]["overlay"] == "prod" and len(renders["prod"]["resolvedConfigurationSha256"]) == 64
assert renders["dev"]["resolvedConfigurationSha256"] != renders["prod"]["resolvedConfigurationSha256"]
PY

# Determinism: a second run over the same inputs yields identical evidence.
run_assembler "${work}/repo" "${work}/out2" "${work}/evidence2" >/dev/null
cmp -s "${evidence_json}" "${work}/evidence2/release-evidence.json" || { echo "FAIL: release evidence is not deterministic" >&2; failures=$((failures + 1)); }
cmp -s "${params}" "${work}/out2/deploy-parameters" || { echo "FAIL: deploy parameters are not deterministic" >&2; failures=$((failures + 1)); }
cmp -s "${skaffold}" "${work}/out2/skaffold.yaml" || { echo "FAIL: skaffold.yaml is not deterministic" >&2; failures=$((failures + 1)); }

# A profile without an overlay file renders base values only.
run_assembler "${work}/repo" "${work}/out3" "${work}/evidence3" --profile pilot=pilot >/dev/null
assert_contains "${work}/out3/skaffold.yaml" '  - name: pilot'
assert_not_contains "${work}/out3/skaffold.yaml" 'values-pilot.yaml' "missing overlay is not referenced"
[ -f "${work}/evidence3/rendered/identity-pilot.yaml" ] || { echo "FAIL: pilot render missing" >&2; failures=$((failures + 1)); }

# A workload without a matching identity renders without the binding and the
# profile then rejects the secret mount (no Workload Identity).
expect_assemble_fail "secret mount without identity binding" "requires identity.googleServiceAccount" "${work}/repo" \
  --allow-file-dependencies --profile dev=dev --image "yourown-chat-identity-api=${api_image}" --image "yourown-chat-identity-migrate=${migrate_image}" --secret-project example-project

# --- contract rejections -----------------------------------------------------------
fresh_repo "${work}/r1"; sedi "${work}/r1/helm/release.yaml" '/^    namespace: identity$/d'
expect_assemble_fail "manifest without namespace" "release manifest is invalid" "${work}/r1" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r2"; printf '      identity-admin:\n        image: yourown-chat-identity-admin\n' >> "${work}/r2/helm/release.yaml"
expect_assemble_fail "manifest workload not pinned in Chart.yaml" "must equal the Chart.yaml aliases" "${work}/r2" --allow-file-dependencies "${common_args[@]}" --image "yourown-chat-identity-admin=${api_image}"

fresh_repo "${work}/r3"; sedi "${work}/r3/helm/identity/Chart.yaml" 's/^    version: 0.1.0$/    version: ^0.1.0/'
expect_assemble_fail "dependency version range" "must pin an exact version" "${work}/r3" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r4"; sedi "${work}/r4/helm/identity/Chart.yaml" 's/name: platform-job/name: redis/'
expect_assemble_fail "non-platform dependency" "is not an approved platform profile" "${work}/r4" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r5"; mkdir -p "${work}/r5/helm/identity/templates"; printf 'kind: Pod\n' > "${work}/r5/helm/identity/templates/pod.yaml"
expect_assemble_fail "wrapper with templates" "must not contain templates" "${work}/r5" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r6"
expect_assemble_fail "file:// dependency without the test flag" "file:// repository" "${work}/r6" --chart-registry oci://europe-west3-docker.pkg.dev/example-project/helm "${common_args[@]}"

fresh_repo "${work}/r7"
expect_assemble_fail "image not built for a workload" "no --image provided for yourown-chat-identity-migrate" "${work}/r7" --allow-file-dependencies --profile dev=dev --image "yourown-chat-identity-api=${api_image}" --identity identity-api=identity-api@example-project.iam.gserviceaccount.com --identity identity-migrate=identity-migrate@example-project.iam.gserviceaccount.com --secret-project example-project

fresh_repo "${work}/r8"; printf 'not-a-value\n' > "${work}/r8/helm/identity/secret.txt"
expect_assemble_fail "unexpected file in wrapper" "unexpected file secret.txt" "${work}/r8" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r9"; printf 'identity-api:\n  container:\n    env:\n      DB_PASSWORD: plaintext\n' > "${work}/r9/helm/identity/values-dev.yaml"
expect_assemble_fail "overlay that violates the profile contract" "does not render against the platform contract" "${work}/r9" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r10"; rm "${work}/r10/helm/identity/Chart.lock"
expect_assemble_fail "missing Chart.lock" "Chart.lock must be committed" "${work}/r10" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r11"; sedi "${work}/r11/helm/identity/Chart.yaml" 's#platform/platform-job#platform/platform-worker#; s/name: platform-job/name: platform-worker/'
expect_assemble_fail "stale Chart.lock" "helm dependency build failed" "${work}/r11" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r12"; sedi "${work}/r12/helm/identity/Chart.yaml" "s#file://${repo_root}/helm/platform/platform-service#oci://europe-west3-docker.pkg.dev/other-project/helm#"
expect_assemble_fail "dependency from a foreign registry" "is not the platform chart registry" "${work}/r12" --allow-file-dependencies --chart-registry oci://europe-west3-docker.pkg.dev/example-project/helm "${common_args[@]}"

fresh_repo "${work}/r13"; cp -R "${work}/r13/helm/identity" "${work}/r13/helm/identity-copy"; printf -- '  - name: identity-copy\n    path: helm/identity-copy\n    namespace: identity\n    workloads:\n      identity-api:\n        image: yourown-chat-identity-api\n      identity-migrate:\n        image: yourown-chat-identity-migrate\n' >> "${work}/r13/helm/release.yaml"
expect_assemble_fail "duplicate alias across wrappers" "aliases must be unique" "${work}/r13" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r14"; sedi "${work}/r14/helm/identity/Chart.yaml" 's/^    alias: identity-migrate$/    alias: identity-migrate\n    condition: identity-migrate.enabled/'
expect_assemble_fail "dependency condition" "must not use condition" "${work}/r14" --allow-file-dependencies "${common_args[@]}"

expect_assemble_fail "malformed profile mapping" "must be NAME=OVERLAY" "${work}/repo" --allow-file-dependencies --profile "Prod" --image "yourown-chat-identity-api=${api_image}"
expect_assemble_fail "image with a tag instead of a digest" "must be NAME=ARTIFACT-REGISTRY-REPOSITORY@sha256" "${work}/repo" --allow-file-dependencies --profile dev=dev --image yourown-chat-identity-api=europe-west3-docker.pkg.dev/example-project/docker/app:1.0.0
expect_assemble_fail "registry outside Artifact Registry" "must be an Artifact Registry OCI path" "${work}/repo" --chart-registry oci://ghcr.io/example/charts --profile dev=dev

finish
