#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

chart=platform-job
rendered="$(mktemp)"; second="$(mktemp)"; cron="$(mktemp)"; other="$(mktemp)"
trap 'rm -f "${rendered}" "${second}" "${cron}" "${other}"' EXIT

render "${chart}" job-valid identity > "${rendered}"
render "${chart}" job-valid identity > "${second}"
cmp -s "${rendered}" "${second}" || { echo "FAIL: render is not deterministic" >&2; failures=$((failures + 1)); }
assert_platform_invariants "${rendered}"
golden "${rendered}" job-valid

assert_count_regex "${rendered}" '^kind: Job$' 1
assert_count_regex "${rendered}" '^kind: NetworkPolicy$' 1
assert_count_regex "${rendered}" '^kind: SecretProviderClass$' 1
assert_not_regex "${rendered}" '^kind: Service$' "job has no Service"
assert_not_contains "${rendered}" 'readinessProbe' "job uses completion status, not probes"
assert_not_contains "${rendered}" 'livenessProbe' "job uses completion status, not probes"
assert_contains "${rendered}" 'ingress: []'
assert_contains "${rendered}" 'backoffLimit: 8'
assert_contains "${rendered}" 'activeDeadlineSeconds: 1800'
assert_contains "${rendered}" 'ttlSecondsAfterFinished: 86400'
assert_contains "${rendered}" 'restartPolicy: OnFailure'
assert_contains "${rendered}" 'secrets/yourown-chat-bootstrap-password/versions/3"'
assert_contains "${rendered}" 'path: "bootstrap-password"'

# A new image digest produces a new immutable Job name; the same inputs keep it.
job_name="$(awk '/^kind: Job$/ { injob = 1 } injob && /^  name: / { print $2; exit }' "${rendered}")"
[[ "${job_name}" =~ ^identity-migrate-[0-9a-f]{12}$ ]] || { echo "FAIL: unexpected Job name ${job_name}" >&2; failures=$((failures + 1)); }
render "${chart}" job-valid identity --set image.digest=europe-west3-docker.pkg.dev/example-project/docker/yourown-chat-identity-migrate@sha256:0000000000000000000000000000000000000000000000000000000000000000 > "${other}"
other_name="$(awk '/^kind: Job$/ { injob = 1 } injob && /^  name: / { print $2; exit }' "${other}")"
[ "${job_name}" != "${other_name}" ] || { echo "FAIL: Job name must change with the image digest" >&2; failures=$((failures + 1)); }

# CronJob variant.
render "${chart}" job-cron-valid identity > "${cron}"
assert_platform_invariants "${cron}"
golden "${cron}" job-cron-valid
assert_count_regex "${cron}" '^kind: CronJob$' 1
assert_contains "${cron}" 'schedule: "15 3 * * *"'
assert_contains "${cron}" 'concurrencyPolicy: Forbid'
assert_contains "${cron}" 'startingDeadlineSeconds: 300'
assert_contains "${cron}" 'restartPolicy: Never'
assert_contains "${cron}" 'priorityClassName: development'
assert_contains "${cron}" 'args: ["--prune"]'

expect_fail "CronJob without schedule" "schedule" "${chart}" job-valid identity --set job.kind=CronJob
expect_fail "Job with schedule" "job.schedule is only valid when job.kind is CronJob" "${chart}" job-valid identity --set 'job.schedule=0 * * * *'
expect_fail "job cannot declare ports" "ports.*not allowed" "${chart}" job-valid identity --set-json 'container.ports=[{"name":"http","port":8080}]'
expect_fail "job cannot declare probes" "health.*not allowed" "${chart}" job-valid identity --set-json 'container.health={"port":"http"}'
expect_fail "job accepts no ingress rules" "ingress.*not allowed" "${chart}" job-valid identity --set-json 'network.ingress=[]'
expect_fail "job has no replica model" "replicas.*not allowed" "${chart}" job-valid identity --set runtime.replicas=2
expect_fail "backoff above bound" "backoffLimit" "${chart}" job-valid identity --set job.backoffLimit=11
expect_fail "unbounded deadline" "activeDeadlineSeconds" "${chart}" job-valid identity --set job.activeDeadlineSeconds=999999
expect_fail "Always restart policy" "restartPolicy" "${chart}" job-valid identity --set job.restartPolicy=Always
expect_fail "Allow concurrency" "concurrencyPolicy" "${chart}" job-cron-valid identity --set job.concurrencyPolicy=Allow
expect_fail "bad cron expression" "schedule" "${chart}" job-cron-valid identity --set 'job.schedule=every day'

finish
