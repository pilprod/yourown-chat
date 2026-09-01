#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 6 ]]; then
  printf 'usage: %s VULNERABILITIES_JSON COMPONENT ARCHITECTURE IMAGE_REFERENCE SCAN_ID OUTPUT_JSON\n' "$0" >&2
  exit 2
fi

vulnerabilities_json="$1"
component="$2"
architecture="$3"
image_reference="$4"
scan_id="$5"
output_json="$6"

evaluator_sha256="$(sha256sum "$0" | cut -d' ' -f1)"
input_sha256="$(sha256sum "${vulnerabilities_json}" | cut -d' ' -f1)"

[[ -f "${vulnerabilities_json}" ]]
[[ "${component}" =~ ^[a-z0-9-]+$ ]]
[[ "${architecture}" =~ ^[a-z0-9-]+$ ]]
[[ "${image_reference}" =~ ^europe-west3-docker\.pkg\.dev/yourown-chat/kagent-staging/kagent/${component}@sha256:[0-9a-f]{64}$ ]]
[[ "${scan_id}" =~ ^projects/yourown-chat/locations/europe/scans/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]

output_dir="$(dirname "${output_json}")"
[[ -d "${output_dir}" ]]
temporary_output="$(mktemp "${output_dir}/.scan-policy.XXXXXX")"
validated_input="$(mktemp "${output_dir}/.scan-input.XXXXXX")"
trap 'rm -f "${temporary_output}" "${validated_input}"' EXIT

# jq deliberately follows JSON's last-key-wins behavior and therefore cannot
# be the first parser on security evidence: a duplicated severity key could
# otherwise hide a HIGH value. Python's object_pairs_hook rejects duplicates
# before any semantic evaluation. The nested type and enum checks also ensure
# a future Container Analysis schema drift cannot silently turn a blocking
# severity into a non-match.
python3 - "${vulnerabilities_json}" "${validated_input}" "${image_reference}" <<'PY'
import json
import re
import sys


class ScanSchemaError(ValueError):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ScanSchemaError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def require(condition, message):
    if not condition:
        raise ScanSchemaError(message)


input_path, output_path, expected_reference = sys.argv[1:]
severities = {
    "MINIMAL",
    "LOW",
    "MEDIUM",
    "HIGH",
    "CRITICAL",
}
version_kinds = {"VERSION_KIND_UNSPECIFIED", "NORMAL", "MINIMUM", "MAXIMUM"}
occurrence_pattern = re.compile(
    r"^projects/yourown-chat/locations/europe/occurrences/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
note_pattern = re.compile(r"^projects/goog-vulnz/notes/CVE-[0-9]{4}-[0-9]{4,}$")
package_type_pattern = re.compile(r"^[A-Z][A-Z0-9_+-]*$")

try:
    with open(input_path, "r", encoding="utf-8") as source:
        document = json.load(source, object_pairs_hook=reject_duplicate_keys)

    require(isinstance(document, list), "root must be an array")
    seen_occurrences = set()
    seen_finding_tuples = set()
    for finding_index, finding in enumerate(document):
        prefix = f"finding[{finding_index}]"
        require(isinstance(finding, dict), f"{prefix} must be an object")
        require(finding.get("kind") == "VULNERABILITY", f"{prefix}.kind is invalid")

        occurrence = finding.get("name")
        require(isinstance(occurrence, str), f"{prefix}.name must be a string")
        require(occurrence_pattern.fullmatch(occurrence) is not None, f"{prefix}.name is invalid")
        require(occurrence not in seen_occurrences, f"{prefix}.name is duplicated")
        seen_occurrences.add(occurrence)

        note_name = finding.get("noteName")
        require(isinstance(note_name, str), f"{prefix}.noteName must be a string")
        require(note_pattern.fullmatch(note_name) is not None, f"{prefix}.noteName is invalid")
        require(
            finding.get("resourceUri") == expected_reference,
            f"{prefix}.resourceUri does not match the scanned child manifest",
        )

        vulnerability = finding.get("vulnerability")
        require(isinstance(vulnerability, dict), f"{prefix}.vulnerability must be an object")
        effective_severity = vulnerability.get("effectiveSeverity")
        require(
            isinstance(effective_severity, str) and effective_severity in severities,
            f"{prefix}.vulnerability.effectiveSeverity is invalid",
        )
        if "severity" in vulnerability:
            severity = vulnerability["severity"]
            require(
                isinstance(severity, str) and severity in severities,
                f"{prefix}.vulnerability.severity is invalid",
            )
        description = vulnerability.get("shortDescription")
        require(
            isinstance(description, str) and description,
            f"{prefix}.vulnerability.shortDescription is invalid",
        )

        package_issues = vulnerability.get("packageIssue")
        require(
            isinstance(package_issues, list) and package_issues,
            f"{prefix}.vulnerability.packageIssue must be a non-empty array",
        )
        for issue_index, issue in enumerate(package_issues):
            issue_prefix = f"{prefix}.vulnerability.packageIssue[{issue_index}]"
            require(isinstance(issue, dict), f"{issue_prefix} must be an object")
            issue_severity = issue.get("effectiveSeverity")
            require(
                isinstance(issue_severity, str) and issue_severity in severities,
                f"{issue_prefix}.effectiveSeverity is invalid",
            )
            affected_package = issue.get("affectedPackage")
            require(
                isinstance(affected_package, str) and affected_package,
                f"{issue_prefix}.affectedPackage is invalid",
            )
            package_type = issue.get("packageType")
            require(
                isinstance(package_type, str)
                and package_type_pattern.fullmatch(package_type) is not None,
                f"{issue_prefix}.packageType is invalid",
            )
            affected_version = issue.get("affectedVersion")
            require(isinstance(affected_version, dict), f"{issue_prefix}.affectedVersion must be an object")
            for field in ("fullName", "name"):
                value = affected_version.get(field)
                require(
                    isinstance(value, str) and value,
                    f"{issue_prefix}.affectedVersion.{field} is invalid",
                )
            version_kind = affected_version.get("kind")
            require(
                isinstance(version_kind, str) and version_kind in version_kinds,
                f"{issue_prefix}.affectedVersion.kind is invalid",
            )
            if "revision" in affected_version:
                require(
                    isinstance(affected_version["revision"], str),
                    f"{issue_prefix}.affectedVersion.revision is invalid",
                )
            finding_tuple = (
                note_name,
                finding["resourceUri"],
                effective_severity,
                affected_package,
                package_type,
                affected_version["kind"],
                affected_version["fullName"],
                affected_version["name"],
                affected_version.get("revision", ""),
                issue_severity,
            )
            require(
                finding_tuple not in seen_finding_tuples,
                f"{issue_prefix} duplicates a previously reported finding",
            )
            seen_finding_tuples.add(finding_tuple)

    with open(output_path, "w", encoding="utf-8") as destination:
        json.dump(document, destination, sort_keys=True, separators=(",", ":"))
        destination.write("\n")
except (OSError, json.JSONDecodeError, ScanSchemaError) as error:
    print(f"Container Analysis vulnerability JSON rejected: {error}", file=sys.stderr)
    raise SystemExit(1)
PY

# Google Container Analysis currently treats the fresh Istio pseudo-version
# below as older than several historical 1.x fixes. The exception is scoped to
# the controller and its independently reviewed amd64/arm64 child manifests.
# Every other HIGH/CRITICAL finding stays fail-closed. CVE-2022-31045 is
# deliberately eligible only if Google raises its effective severity from
# MEDIUM to HIGH/CRITICAL.
jq -e \
  --arg component "${component}" \
  --arg architecture "${architecture}" \
  --arg image_reference "${image_reference}" \
  --arg scan_id "${scan_id}" \
  --arg evaluator_sha256 "${evaluator_sha256}" \
  --arg input_sha256 "${input_sha256}" \
  '
    def high_or_critical:
      . == "HIGH" or . == "CRITICAL";
    def reviewed_cve:
      . == "CVE-2022-23635" or
      . == "CVE-2021-39156" or
      . == "CVE-2021-39155" or
      . == "CVE-2019-14993" or
      . == "CVE-2022-31045";
    def high_or_critical_finding:
      (.vulnerability.effectiveSeverity | high_or_critical) or
      any(.vulnerability.packageIssue[]?; .effectiveSeverity | high_or_critical);
    def evaluated_finding:
      . as $finding
      | ($finding.vulnerability.shortDescription // "") as $cve
      | ($finding.vulnerability.packageIssue // []) as $issues
      | ($issues[0] // {}) as $issue
      | {
          cve: $cve,
          effectiveSeverity: ($finding.vulnerability.effectiveSeverity // ""),
          occurrence: ($finding.name // ""),
          noteName: ($finding.noteName // ""),
          resourceUri: ($finding.resourceUri // ""),
          package: ($issue.affectedPackage // ""),
          packageType: ($issue.packageType // ""),
          affectedVersion: ($issue.affectedVersion.fullName // ""),
          matchesReviewedException: (
            $component == "controller" and
            ($architecture == "amd64" or $architecture == "arm64") and
            ($finding.kind // "") == "VULNERABILITY" and
            ($finding.resourceUri // "") == $image_reference and
            ($finding.noteName // "") == ("projects/goog-vulnz/notes/" + $cve) and
            ($cve | reviewed_cve) and
            ($finding.vulnerability.effectiveSeverity | high_or_critical) and
            ($issues | length) == 1 and
            ($issue.effectiveSeverity // "") == ($finding.vulnerability.effectiveSeverity // "") and
            ($issue.effectiveSeverity | high_or_critical) and
            ($issue.affectedPackage // "") == "istio.io/istio" and
            ($issue.packageType // "") == "GO" and
            ($issue.affectedVersion.kind // "") == "NORMAL" and
            ($issue.affectedVersion.fullName // "") == "0.0.0-20260820015531-47320ba1a73b" and
            ($issue.affectedVersion.name // "") == "0.0.0-20260820015531" and
            ($issue.affectedVersion.revision // "") == "47320ba1a73b"
          )
        };

    if type != "array" then
      error("vulnerability result must be a JSON array")
    else
      .
    end
    | [
        .[]
        | select(
            type != "object" or
            (.kind // "") != "VULNERABILITY" or
            ((.resourceUri // null) | type) != "string" or
            ((.vulnerability // null) | type) != "object" or
            ((.vulnerability.effectiveSeverity // null) | type) != "string" or
            ((.vulnerability.packageIssue // null) | type) != "array"
          )
      ] as $invalid_entries
    | if ($invalid_entries | length) != 0 then
        error("vulnerability result does not match the fail-closed occurrence schema")
      else
        .
      end
    | [ .[] | select(high_or_critical_finding) | evaluated_finding ] as $evaluated
    | [ $evaluated[] | select(.matchesReviewedException) ] as $suppressed
    | [ $evaluated[] | select(.matchesReviewedException | not) ] as $blocking
    | ($suppressed | map(.cve) | length) as $suppressed_count
    | ($suppressed | map(.cve) | unique | length) as $unique_suppressed_count
    | (if $suppressed_count != $unique_suppressed_count then
         $blocking + [{
           cve: "DUPLICATE_REVIEWED_FINDING",
           effectiveSeverity: "HIGH",
           occurrence: "",
           noteName: "",
           resourceUri: $image_reference,
           package: "istio.io/istio",
           packageType: "GO",
           affectedVersion: "0.0.0-20260820015531-47320ba1a73b",
           matchesReviewedException: false
         }]
       else
         $blocking
       end) as $effective_blocking
    | {
        schemaVersion: 1,
        policy: {
          id: "kagent-istio-pseudoversion-google-scanner-v1",
          evaluatorSha256: $evaluator_sha256,
          rationale: "Google Container Analysis orders the reviewed 2026 Istio pseudo-version below historical 1.x fixes; the 2026-08-31 Go vulnerability database review did not report these CVEs for that module version.",
          reviewedFrom: {
            cloudBuildId: "1c343779-8f5f-4455-a7ab-f6e4d9480892",
            goVulnerabilityDatabase: {
              checkedAt: "2026-08-31",
              index: "https://vuln.go.dev/index/modules.json",
              module: "istio.io/istio",
              targetVersion: "0.0.0-20260820015531-47320ba1a73b",
              reportedFixes: [
                {
                  id: "GO-2026-5289",
                  fixed: "0.0.0-20260403004500-692e460c342d"
                },
                {
                  id: "GO-2026-5363",
                  fixed: "0.0.0-20260410004459-189832a289c1"
                }
              ]
            },
            scans: [
              {
                architecture: "amd64",
                scanId: "projects/yourown-chat/locations/europe/scans/378951db-0c40-4927-985b-ca59acc2d38f",
                imageReference: "europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent/controller@sha256:0bedff1956c19d5607476e5a49687dd8764ea276783fb2207d042f4e9b2ab912"
              },
              {
                architecture: "arm64",
                scanId: "projects/yourown-chat/locations/europe/scans/2ee676e7-025e-4b99-9e9a-af493cbc93e6",
                imageReference: "europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent/controller@sha256:26b2f3482b41590e341dff173870bae6e09e1201571e8772dfd05912e34bd357"
              }
            ]
          },
          exactScope: {
            component: "controller",
            os: "linux",
            architectures: ["amd64", "arm64"],
            package: "istio.io/istio",
            packageType: "GO",
            upstreamModuleVersion: "v0.0.0-20260820015531-47320ba1a73b",
            scannerAffectedVersion: "0.0.0-20260820015531-47320ba1a73b",
            eligibleEffectiveSeverities: ["HIGH", "CRITICAL"],
            cves: [
              "CVE-2019-14993",
              "CVE-2021-39155",
              "CVE-2021-39156",
              "CVE-2022-23635",
              "CVE-2022-31045"
            ]
          }
        },
        rawVulnerabilitiesSha256: $input_sha256,
        target: {
          component: $component,
          os: "linux",
          architecture: $architecture,
          imageReference: $image_reference,
          scanId: $scan_id
        },
        decision: (if ($effective_blocking | length) == 0 then "pass" else "block" end),
        highCriticalFindingCount: ($evaluated | length),
        suppressedHighCriticalFindings: ($suppressed | map(del(.matchesReviewedException)) | sort_by(.cve)),
        blockingHighCriticalFindings: ($effective_blocking | map(del(.matchesReviewedException)) | sort_by(.cve))
      }
  ' "${validated_input}" > "${temporary_output}"

mv "${temporary_output}" "${output_json}"
rm -f "${validated_input}"
trap - EXIT

if [[ "$(jq -er '.decision' "${output_json}")" != "pass" ]]; then
  jq -c '{target, blockingHighCriticalFindings}' "${output_json}" >&2
  printf 'High or Critical vulnerability blocks kagent image %s for linux/%s\n' \
    "${component}" "${architecture}" >&2
  exit 1
fi
