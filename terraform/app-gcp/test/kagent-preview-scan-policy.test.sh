#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
evaluator="${root_dir}/terraform/app-gcp/modules/kagent-preview-publisher/scripts/evaluate-scan-vulnerabilities.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "${temporary_dir}"' EXIT
test_jq="$(command -v jq)"
export TEST_JQ_REAL="${test_jq}"
trusted_jq="${temporary_dir}/trusted-jq"
fake_bin="${temporary_dir}/bin"
mkdir -p "${fake_bin}"
cat > "${trusted_jq}" <<'SCRIPT'
#!/usr/bin/env bash
: "${TEST_JQ_REAL:?TEST_JQ_REAL is required}"
exec "${TEST_JQ_REAL}" "$@"
SCRIPT
chmod 0555 "${trusted_jq}"
cat > "${fake_bin}/jq" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: > "${PATH_JQ_CALLED_MARKER}"
printf 'scan evaluator must use only explicit KAGENT_JQ_PATH\n' >&2
exit 98
SCRIPT
chmod 0555 "${fake_bin}/jq"
export KAGENT_JQ_PATH="${trusted_jq}"
export KAGENT_TRUSTED_JQ_SHA256="$(sha256sum "${trusted_jq}" | cut -d' ' -f1)"
export PATH_JQ_CALLED_MARKER="${temporary_dir}/path-jq-called"
export PATH="${fake_bin}:${PATH}"

reference="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent/controller@sha256:0bedff1956c19d5607476e5a49687dd8764ea276783fb2207d042f4e9b2ab912"
scan_id="projects/yourown-chat/locations/europe/scans/378951db-0c40-4927-985b-ca59acc2d38f"
arm_reference="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent/controller@sha256:26b2f3482b41590e341dff173870bae6e09e1201571e8772dfd05912e34bd357"
arm_scan_id="projects/yourown-chat/locations/europe/scans/2ee676e7-025e-4b99-9e9a-af493cbc93e6"
golang_reference="europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent/golang-adk@sha256:0bedff1956c19d5607476e5a49687dd8764ea276783fb2207d042f4e9b2ab912"

fail() {
  printf 'kagent preview scan policy test failed: %s\n' "$1" >&2
  exit 1
}

write_reviewed_fixture() {
  local output="$1"
  local fixture_reference="${2:-${reference}}"
  "${test_jq}" -n --arg reference "${fixture_reference}" '
    def finding($cve; $severity; $occurrence): {
      kind: "VULNERABILITY",
      name: ("projects/yourown-chat/locations/europe/occurrences/" + $occurrence),
      noteName: ("projects/goog-vulnz/notes/" + $cve),
      resourceUri: $reference,
      vulnerability: {
        effectiveSeverity: $severity,
        shortDescription: $cve,
        packageIssue: [{
          affectedPackage: "istio.io/istio",
          affectedVersion: {
            fullName: "0.0.0-20260820015531-47320ba1a73b",
            kind: "NORMAL",
            name: "0.0.0-20260820015531",
            revision: "47320ba1a73b"
          },
          effectiveSeverity: $severity,
          packageType: "GO"
        }]
      }
    };
    [
      finding("CVE-2022-23635"; "HIGH"; "00000000-0000-4000-8000-000000000001"),
      finding("CVE-2021-39156"; "HIGH"; "00000000-0000-4000-8000-000000000002"),
      finding("CVE-2021-39155"; "HIGH"; "00000000-0000-4000-8000-000000000003"),
      finding("CVE-2019-14993"; "HIGH"; "00000000-0000-4000-8000-000000000004"),
      finding("CVE-2022-31045"; "MEDIUM"; "00000000-0000-4000-8000-000000000005")
    ]
  ' > "${output}"
}

expect_pass() {
  local name="$1"
  local input="$2"
  local component="${3:-controller}"
  local architecture="${4:-amd64}"
  local target_reference="${5:-${reference}}"
  local target_scan_id="${6:-${scan_id}}"
  local output="${temporary_dir}/${name}-decision.json"

  "${evaluator}" "${input}" "${component}" "${architecture}" \
    "${target_reference}" "${target_scan_id}" "${output}" ||
    fail "${name} should pass"
  "${test_jq}" -e '.decision == "pass" and (.blockingHighCriticalFindings | length) == 0' \
    "${output}" >/dev/null || fail "${name} pass decision is incomplete"
}

expect_block() {
  local name="$1"
  local input="$2"
  local component="${3:-controller}"
  local architecture="${4:-amd64}"
  local target_reference="${5:-${reference}}"
  local target_scan_id="${6:-${scan_id}}"
  local output="${temporary_dir}/${name}-decision.json"

  if "${evaluator}" "${input}" "${component}" "${architecture}" \
    "${target_reference}" "${target_scan_id}" "${output}" 2>/dev/null; then
    fail "${name} should block"
  fi
  "${test_jq}" -e '.decision == "block" and (.blockingHighCriticalFindings | length) > 0' \
    "${output}" >/dev/null || fail "${name} block decision is not auditable"
}

expect_fail_closed() {
  local name="$1"
  local input="$2"
  local output="${temporary_dir}/${name}-decision.json"

  if "${evaluator}" "${input}" controller amd64 \
    "${reference}" "${scan_id}" "${output}" 2>/dev/null; then
    fail "${name} should fail closed"
  fi
}

reviewed="${temporary_dir}/reviewed.json"
write_reviewed_fixture "${reviewed}"
expect_pass exact-reviewed-findings "${reviewed}"

exact_decision="${temporary_dir}/exact-reviewed-findings-decision.json"
expected_evaluator_sha="$(sha256sum "${evaluator}" | cut -d' ' -f1)"
expected_raw_sha="$(sha256sum "${reviewed}" | cut -d' ' -f1)"
"${test_jq}" -e '
  .highCriticalFindingCount == 4 and
  (.suppressedHighCriticalFindings | length) == 4 and
  (.policy.exactScope.cves | index("CVE-2022-31045")) != null and
  .policy.exactScope.architectures == ["amd64", "arm64"] and
  .policy.exactScope.upstreamModuleVersion == "v0.0.0-20260820015531-47320ba1a73b" and
  .policy.reviewedFrom.cloudBuildId == "1c343779-8f5f-4455-a7ab-f6e4d9480892" and
  .policy.reviewedFrom.goVulnerabilityDatabase.reportedFixes == [
    {id: "GO-2026-5289", fixed: "0.0.0-20260403004500-692e460c342d"},
    {id: "GO-2026-5363", fixed: "0.0.0-20260410004459-189832a289c1"}
  ] and
  .policy.evaluatorSha256 == $evaluator_sha and
  .rawVulnerabilitiesSha256 == $raw_sha
' --arg evaluator_sha "${expected_evaluator_sha}" --arg raw_sha "${expected_raw_sha}" \
  "${exact_decision}" >/dev/null || fail 'exact reviewed decision lost its audit scope or hash binding'

raised="${temporary_dir}/raised-31045.json"
"${test_jq}" '
  .[4].vulnerability.effectiveSeverity = "HIGH" |
  .[4].vulnerability.packageIssue[0].effectiveSeverity = "HIGH"
' "${reviewed}" > "${raised}"
expect_pass raised-31045-is-reviewed "${raised}"
"${test_jq}" -e '
  .highCriticalFindingCount == 5 and
  (.suppressedHighCriticalFindings | map(.cve) | index("CVE-2022-31045")) != null
' "${temporary_dir}/raised-31045-is-reviewed-decision.json" >/dev/null ||
  fail 'CVE-2022-31045 must be eligible only after effective severity becomes HIGH/CRITICAL'

reviewed_arm="${temporary_dir}/reviewed-arm64.json"
write_reviewed_fixture "${reviewed_arm}" "${arm_reference}"
expect_pass exact-reviewed-arm64-findings "${reviewed_arm}" controller arm64 \
  "${arm_reference}" "${arm_scan_id}"

wrong_version="${temporary_dir}/wrong-version.json"
"${test_jq}" '.[0].vulnerability.packageIssue[0].affectedVersion.fullName = "1.11.6"' \
  "${reviewed}" > "${wrong_version}"
expect_block wrong-version "${wrong_version}"

wrong_package="${temporary_dir}/wrong-package.json"
"${test_jq}" '.[0].vulnerability.packageIssue[0].affectedPackage = "example.invalid/istio"' \
  "${reviewed}" > "${wrong_package}"
expect_block wrong-package "${wrong_package}"

reviewed_golang="${temporary_dir}/reviewed-golang.json"
write_reviewed_fixture "${reviewed_golang}" "${golang_reference}"
expect_block wrong-component "${reviewed_golang}" golang-adk amd64 "${golang_reference}"
expect_block wrong-architecture "${reviewed}" controller ppc64le

wrong_cve="${temporary_dir}/wrong-cve.json"
"${test_jq}" '
  .[0].vulnerability.shortDescription = "CVE-2099-0001" |
  .[0].noteName = "projects/goog-vulnz/notes/CVE-2099-0001"
' "${reviewed}" > "${wrong_cve}"
expect_block wrong-cve "${wrong_cve}"

extra_finding="${temporary_dir}/extra-finding.json"
"${test_jq}" '
  . + [
    (.[0]
      | .name = "projects/yourown-chat/locations/europe/occurrences/00000000-0000-4000-8000-000000000006"
      | .noteName = "projects/goog-vulnz/notes/CVE-2026-63073"
      | .vulnerability.shortDescription = "CVE-2026-63073"
      | .vulnerability.effectiveSeverity = "CRITICAL"
      | .vulnerability.packageIssue[0].affectedPackage = "openssl"
      | .vulnerability.packageIssue[0].affectedVersion = {
          fullName: "3.5.7-r0",
          kind: "NORMAL",
          name: "3.5.7",
          revision: "r0"
        }
      | .vulnerability.packageIssue[0].effectiveSeverity = "CRITICAL"
      | .vulnerability.packageIssue[0].packageType = "OS")
  ]
' "${reviewed}" > "${extra_finding}"
expect_block extra-high-critical-finding "${extra_finding}"

malformed="${temporary_dir}/malformed.json"
"${test_jq}" 'del(.[0].vulnerability.packageIssue)' "${reviewed}" > "${malformed}"
expect_fail_closed malformed-scanner-schema "${malformed}"

duplicate_key="${temporary_dir}/duplicate-key.json"
awk '
  !replaced && /"effectiveSeverity": "HIGH"/ {
    sub(/"effectiveSeverity": "HIGH"/, "\"effectiveSeverity\": \"HIGH\", \"effectiveSeverity\": \"LOW\"")
    replaced = 1
  }
  { print }
' "${reviewed}" > "${duplicate_key}"
expect_fail_closed duplicate-json-key "${duplicate_key}"

numeric_issue_severity="${temporary_dir}/numeric-issue-severity.json"
"${test_jq}" '.[0].vulnerability.packageIssue[0].effectiveSeverity = 123' \
  "${reviewed}" > "${numeric_issue_severity}"
expect_fail_closed numeric-nested-severity "${numeric_issue_severity}"

unknown_top_severity="${temporary_dir}/unknown-top-severity.json"
"${test_jq}" '.[0].vulnerability.effectiveSeverity = "URGENT"' \
  "${reviewed}" > "${unknown_top_severity}"
expect_fail_closed unknown-top-severity "${unknown_top_severity}"

unspecified_top_severity="${temporary_dir}/unspecified-top-severity.json"
"${test_jq}" '.[0].vulnerability.effectiveSeverity = "SEVERITY_UNSPECIFIED"' \
  "${reviewed}" > "${unspecified_top_severity}"
expect_fail_closed unspecified-top-severity "${unspecified_top_severity}"

unspecified_issue_severity="${temporary_dir}/unspecified-issue-severity.json"
"${test_jq}" '.[0].vulnerability.packageIssue[0].effectiveSeverity = "SEVERITY_UNSPECIFIED"' \
  "${reviewed}" > "${unspecified_issue_severity}"
expect_fail_closed unspecified-nested-severity "${unspecified_issue_severity}"

duplicate_occurrence="${temporary_dir}/duplicate-occurrence.json"
"${test_jq}" '.[1].name = .[0].name' "${reviewed}" > "${duplicate_occurrence}"
expect_fail_closed duplicate-occurrence "${duplicate_occurrence}"

duplicate_finding_tuple="${temporary_dir}/duplicate-finding-tuple.json"
"${test_jq}" '. + [(.[4] | .name = "projects/yourown-chat/locations/europe/occurrences/00000000-0000-4000-8000-000000000006")]' \
  "${reviewed}" > "${duplicate_finding_tuple}"
expect_fail_closed duplicate-finding-tuple "${duplicate_finding_tuple}"

wrong_resource="${temporary_dir}/wrong-resource.json"
"${test_jq}" '.[0].resourceUri = "europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent/controller@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "${reviewed}" > "${wrong_resource}"
expect_fail_closed mismatched-resource-uri "${wrong_resource}"

malformed_issue="${temporary_dir}/malformed-issue.json"
"${test_jq}" '.[0].vulnerability.packageIssue[0] = "not-an-object"' \
  "${reviewed}" > "${malformed_issue}"
expect_fail_closed malformed-package-issue "${malformed_issue}"

[[ ! -e "${PATH_JQ_CALLED_MARKER}" ]] ||
  fail 'scan evaluator resolved jq from PATH instead of KAGENT_JQ_PATH'
cp "${trusted_jq}" "${trusted_jq}.good"
printf '#!/usr/bin/env bash\nexit 0\n' > "${trusted_jq}.forged"
chmod 0555 "${trusted_jq}.forged"
mv -f "${trusted_jq}.forged" "${trusted_jq}"
if "${evaluator}" "${reviewed}" controller amd64 \
  "${reference}" "${scan_id}" "${temporary_dir}/tampered-parser.json" >/dev/null 2>&1; then
  fail 'scan evaluator accepted a substituted explicit JSON parser'
fi
mv -f "${trusted_jq}.good" "${trusted_jq}"

printf 'kagent preview scan policy tests passed\n'
