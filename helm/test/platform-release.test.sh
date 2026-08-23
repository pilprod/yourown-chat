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
bash "${repo_root}/helm/platform/release/policy-check.sh" "${prod_render}" || { echo "FAIL: prod render fails policy" >&2; failures=$((failures + 1)); }

# Mixed wrapper: each controller carries the identity of the profile that
# rendered it (Helm named templates are global; identity comes from chart
# metadata, not from a per-chart define).
deployment_doc="$(awk 'BEGIN { RS="---" } /\nkind: Deployment\n/ { print }' "${prod_render}")"
job_doc="$(awk 'BEGIN { RS="---" } /\nkind: Job\n/ { print }' "${prod_render}")"
grep -Fq 'platform.yourown.chat/profile: platform-service' <<<"${deployment_doc}" || { echo "FAIL: Deployment must carry the platform-service profile label" >&2; failures=$((failures + 1)); }
grep -Fq 'helm.sh/chart: "platform-service-0.1.0"' <<<"${deployment_doc}" || { echo "FAIL: Deployment must carry the platform-service chart label" >&2; failures=$((failures + 1)); }
grep -Fq 'platform.yourown.chat/profile: platform-job' <<<"${job_doc}" || { echo "FAIL: Job must carry the platform-job profile label" >&2; failures=$((failures + 1)); }
grep -Fq 'helm.sh/chart: "platform-job-0.1.0"' <<<"${job_doc}" || { echo "FAIL: Job must carry the platform-job chart label" >&2; failures=$((failures + 1)); }
grep -Fq 'app.kubernetes.io/component: platform-job' <<<"${job_doc}" || { echo "FAIL: Job must carry the platform-job component label" >&2; failures=$((failures + 1)); }

# Verification: the generated profiles carry the declared in-cluster checks
# and a per-wrapper verification Job manifest.
assert_contains "${skaffold}" '    verify:'
assert_contains "${skaffold}" '      - name: identity-verify'
assert_contains "${skaffold}" 'curl -sSf --connect-timeout 3 --max-time 10 --retry 30 --retry-all-errors --retry-delay 5 "http://identity-api.identity.svc.cluster.local:8081/readyz"'
assert_contains "${skaffold}" 'jobManifestPath: verify/identity.yaml'
assert_count "${skaffold}" 'jobManifestPath: verify/identity.yaml' 2
[ -f "${work}/out/verify/identity.yaml" ] || { echo "FAIL: verification Job manifest missing" >&2; failures=$((failures + 1)); }
assert_contains "${work}/out/verify/identity.yaml" 'namespace: identity'
assert_contains "${work}/out/verify/identity.yaml" 'app: verify'
assert_contains "${work}/out/verify/identity.yaml" 'automountServiceAccountToken: false'
assert_contains "${prod_render}" 'app: verify'

python3 - "${evidence_json}" "${api_image}" <<'PY' || { echo "FAIL: release evidence is incomplete" >&2; failures=$((failures + 1)); }
import json, sys
e = json.load(open(sys.argv[1]))
assert e["schema"] == "platform.yourown.chat/release-evidence/v1"
assert e["sourceRevision"] == "0123456789abcdef0123456789abcdef01234567"
assert e["platformRevision"] == "fedcba9876543210fedcba9876543210fedcba98"
assert [p["name"] for p in e["profiles"]] == ["dev", "prod"]
assert len(e["releaseParameters"]) == 8
w = e["wrappers"]["identity"]
assert w["verification"] == [{"name": "identity-api-ready", "url": "http://identity-api.identity.svc.cluster.local:8081/readyz"}]
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
  --allow-file-dependencies --profile dev=dev --image "yourown-chat-identity-api=${api_image}" --image "yourown-chat-identity-migrate=${migrate_image}" --secret-project example-project --cluster-dns-ip 10.30.0.10

# --- contract rejections -----------------------------------------------------------
fresh_repo "${work}/r1"; sedi "${work}/r1/helm/release.yaml" '/^    namespace: identity$/d'
expect_assemble_fail "manifest without namespace" "release manifest is invalid" "${work}/r1" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r2"; sedi "${work}/r2/helm/release.yaml" 's/^        identity: identity-migrate$/        identity: identity-migrate\
      identity-admin:\
        image: yourown-chat-identity-admin/'

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
expect_assemble_fail "image not built for a workload" "no --image provided for yourown-chat-identity-migrate" "${work}/r7" --allow-file-dependencies --profile dev=dev --image "yourown-chat-identity-api=${api_image}" --identity identity-api=identity-api@example-project.iam.gserviceaccount.com --identity identity-migrate=identity-migrate@example-project.iam.gserviceaccount.com --secret-project example-project --cluster-dns-ip 10.30.0.10

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

fresh_repo "${work}/r15"; python3 - "${work}/r15/helm/release.yaml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
i=s.index("    verify:")
open(p,"w").write(s[:i])
PY
expect_assemble_fail "network service wrapper without verification" "must declare verify.http checks" "${work}/r15" --allow-file-dependencies "${common_args[@]}"

fresh_repo "${work}/r16"; sedi "${work}/r16/helm/release.yaml" 's#http://identity-api.identity.svc.cluster.local:8081/readyz#https://example.com/readyz#'
expect_assemble_fail "verification outside the cluster" "release manifest is invalid" "${work}/r16" --allow-file-dependencies "${common_args[@]}"

expect_assemble_fail "malformed profile mapping" "must be NAME=OVERLAY" "${work}/repo" --allow-file-dependencies --profile "Prod" --image "yourown-chat-identity-api=${api_image}"
expect_assemble_fail "image with a tag instead of a digest" "must be NAME=ARTIFACT-REGISTRY-REPOSITORY@sha256" "${work}/repo" --allow-file-dependencies --profile dev=dev --image yourown-chat-identity-api=europe-west3-docker.pkg.dev/example-project/docker/app:1.0.0
expect_assemble_fail "registry outside Artifact Registry" "must be an Artifact Registry OCI path" "${work}/repo" --chart-registry oci://ghcr.io/example/charts --profile dev=dev
expect_assemble_fail "missing cluster DNS release parameter" "--cluster-dns-ip is required" "${work}/repo" --allow-file-dependencies --profile dev=dev --image "yourown-chat-identity-api=${api_image}" --image "yourown-chat-identity-migrate=${migrate_image}" --secret-project example-project
expect_assemble_fail "duplicate profile request" "requested more than once" "${work}/repo" --allow-file-dependencies "${common_args[@]}" --profile dev=dev
expect_assemble_fail "cleanup action for an unrequested profile" "references a profile that is not requested" "${work}/repo" --allow-file-dependencies "${common_args[@]}" --cleanup-action cleanup-x=pilot
expect_assemble_fail "actions file without customActions document" "must start with a customActions: document" "${work}/repo" --allow-file-dependencies "${common_args[@]}" --actions "${fixture_dir}/service-valid.yaml"

# --- profile selection, generated cleanup action, platform actions file -----------
fresh_repo "${work}/r20"; sedi "${work}/r20/helm/release.yaml" 's/^    namespace: identity$/    namespace: identity\
    profiles: [prod]/'
expect_assemble_fail "profile without any wrapper" "profile dev selects no wrapper" "${work}/r20" --allow-file-dependencies "${common_args[@]}"
bash "${assembler}" --repo "${work}/r20" --out "${work}/out20" --evidence "${work}/evidence20" --allow-file-dependencies \
  --profile prod=prod "${common_args[@]:4}" >/dev/null
assert_not_contains "${work}/out20/skaffold.yaml" '  - name: dev' "manifest profiles limit the wrapper to prod"
assert_contains "${work}/out20/skaffold.yaml" '  - name: prod'
python3 - "${work}/evidence20/release-evidence.json" <<'PY' || { echo "FAIL: profile membership evidence" >&2; failures=$((failures + 1)); }
import json, sys
e = json.load(open(sys.argv[1]))
assert e["profiles"] == [{"name": "prod", "overlay": "prod", "wrappers": ["identity"]}], e["profiles"]
PY

run_assembler "${work}/repo" "${work}/out21" "${work}/evidence21" --cleanup-action cleanup-identity-dev=dev --actions "${repo_root}/helm/platform/release/actions/mcp-capability-sync.yaml" >/dev/null
golden "${work}/out21/skaffold.yaml" release-skaffold-actions
assert_contains "${work}/out21/skaffold.yaml" 'customActions:'
assert_contains "${work}/out21/skaffold.yaml" '  - name: cleanup-identity-dev'
assert_contains "${work}/out21/skaffold.yaml" 'kubectl --namespace identity scale deployment/identity-api --replicas=0 --ignore-not-found'
assert_not_contains "${work}/out21/skaffold.yaml" 'scale deployment/identity-migrate' "jobs are not scaled by the cleanup action"
assert_contains "${work}/out21/skaffold.yaml" 'cluster_name="${GKE_CLUSTER##*/}"'
assert_contains "${work}/out21/skaffold.yaml" '  - name: sync-cloudflare-mcp-capabilities'
assert_not_contains "${work}/out21/skaffold.yaml" '# Platform-owned Cloud Deploy custom action' "file comments are not copied"
assert_count "${work}/out21/skaffold.yaml" 'customActions:' 1
assert_contains "${work}/evidence21/release-evidence.json" '"platformActions"'
assert_contains "${work}/evidence21/release-evidence.json" 'mcp-capability-sync.yaml'

# The platform action file must equal the action still carried by the legacy
# MCP Skaffold configuration until that file is retired.
legacy_action="$(awk '/^  - name: sync-cloudflare-mcp-capabilities$/ { p=1 } /^  - name: cleanup-mcp-dev$/ { p=0 } p { print }' "${repo_root}/helm/skaffold-mcp.yaml")"
platform_action="$(grep -v '^#' "${repo_root}/helm/platform/release/actions/mcp-capability-sync.yaml" | sed '1{/^customActions:$/d;}')"
[ "${legacy_action}" = "${platform_action}" ] || { echo "FAIL: helm/platform/release/actions/mcp-capability-sync.yaml drifted from the legacy helm/skaffold-mcp.yaml action" >&2; failures=$((failures + 1)); }

finish
