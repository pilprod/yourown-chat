#!/usr/bin/env bash
# Shared helpers for the platform profile chart tests.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
platform_dir="${repo_root}/helm/platform"
fixture_dir="${repo_root}/helm/test/fixtures/platform"
golden_dir="${repo_root}/helm/test/golden/platform"
failures=0

# render <chart> <fixture-name> <namespace> [extra helm args...]
# Writes the manifest to stdout; fails the test when rendering fails.
render() {
  local chart="$1" fixture="$2" namespace="$3"
  shift 3
  helm template "test-${fixture}" "${platform_dir}/${chart}" \
    --namespace "${namespace}" \
    -f "${fixture_dir}/${fixture}.yaml" "$@"
}

# expect_fail <description> <expected-regex> <chart> <fixture> <namespace> [extra helm args...]
# The render must fail and its error output must match the extended regex.
# Schema messages differ between Helm releases, so expectations usually name
# the JSON pointer or dotted path of the rejected value.
expect_fail() {
  local description="$1" expected="$2" chart="$3" fixture="$4" namespace="$5"
  shift 5
  local output status
  set +e
  output="$(helm template "test-${fixture}" "${platform_dir}/${chart}" \
    --namespace "${namespace}" \
    -f "${fixture_dir}/${fixture}.yaml" "$@" 2>&1)"
  status=$?
  set -e
  if [ "${status}" -eq 0 ]; then
    echo "FAIL (rendered but must be rejected): ${description}" >&2
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

# assert_contains <file> <fixed-string> [description]
assert_contains() {
  if grep -Fq -- "$2" "$1"; then return 0; fi
  echo "FAIL: ${3:-expected} — missing: $2" >&2
  failures=$((failures + 1))
}

# assert_not_contains <file> <fixed-string> [description]
assert_not_contains() {
  if ! grep -Fq -- "$2" "$1"; then return 0; fi
  echo "FAIL: ${3:-unexpected} — found: $2" >&2
  failures=$((failures + 1))
}

# assert_not_regex <file> <extended-regex> [description]
assert_not_regex() {
  if ! grep -Eq -- "$2" "$1"; then return 0; fi
  echo "FAIL: ${3:-unexpected} — pattern matched: $2" >&2
  failures=$((failures + 1))
}

# assert_count <file> <fixed-string> <expected-count> [description]
assert_count() {
  local count
  count="$(grep -Fc -- "$2" "$1" || true)"
  if [ "${count}" -eq "$3" ]; then return 0; fi
  echo "FAIL: ${4:-count} — expected $3 occurrences of '$2', found ${count}" >&2
  failures=$((failures + 1))
}

# assert_count_regex <file> <extended-regex> <expected-count> [description]
assert_count_regex() {
  local count
  count="$(grep -Ec -- "$2" "$1" || true)"
  if [ "${count}" -eq "$3" ]; then return 0; fi
  echo "FAIL: ${4:-count} — expected $3 lines matching '$2', found ${count}" >&2
  failures=$((failures + 1))
}

# golden <rendered-file> <golden-name>
# Compares against the committed snapshot; UPDATE_GOLDEN=1 rewrites it.
golden() {
  local rendered="$1" name="$2" target="${golden_dir}/$2.yaml"
  if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
    mkdir -p "${golden_dir}"
    cp "${rendered}" "${target}"
    echo "updated golden ${name}"
    return 0
  fi
  if [ ! -f "${target}" ]; then
    echo "FAIL: golden snapshot ${target} is missing (run with UPDATE_GOLDEN=1)" >&2
    failures=$((failures + 1))
    return 0
  fi
  if ! diff -u "${target}" "${rendered}" >&2; then
    echo "FAIL: rendered output differs from golden ${name}" >&2
    failures=$((failures + 1))
  fi
}

# Platform-owned invariants every profile render must satisfy. The policy
# check itself is shared with the release assembler
# (helm/platform/release/policy-check.sh); the test adds label and annotation
# expectations that only hold for a direct profile render.
assert_platform_invariants() {
  local file="$1"
  if ! bash "${repo_root}/helm/platform/release/policy-check.sh" "${file}"; then
    echo "FAIL: platform policy check rejected ${file}" >&2
    failures=$((failures + 1))
  fi
  assert_contains "${file}" 'automountServiceAccountToken: false' "service account token is not mounted"
  assert_contains "${file}" 'enableServiceLinks: false' "service links disabled"
  assert_contains "${file}" 'runAsNonRoot: true' "non-root"
  assert_contains "${file}" 'allowPrivilegeEscalation: false' "no privilege escalation"
  assert_contains "${file}" 'readOnlyRootFilesystem: true' "read-only root filesystem"
  assert_contains "${file}" 'type: RuntimeDefault' "RuntimeDefault seccomp"
  assert_contains "${file}" 'drop: ["ALL"]' "capabilities dropped"
  assert_contains "${file}" 'k8s-app: kube-dns' "DNS egress baseline"
  assert_contains "${file}" 'platform.yourown.chat/image-digest:' "digest annotation"
}

finish() {
  if [ "${failures}" -ne 0 ]; then
    echo "${failures} assertion(s) failed in $(basename "$0")" >&2
    exit 1
  fi
  echo "$(basename "$0") passed"
}
