#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

chart=platform-worker
rendered="$(mktemp)"; second="$(mktemp)"; running="$(mktemp)"
trap 'rm -f "${rendered}" "${second}" "${running}"' EXIT

render "${chart}" worker-valid yourown-agents > "${rendered}"
render "${chart}" worker-valid yourown-agents > "${second}"
cmp -s "${rendered}" "${second}" || { echo "FAIL: render is not deterministic" >&2; failures=$((failures + 1)); }
assert_platform_invariants "${rendered}"
golden "${rendered}" worker-valid

assert_count_regex "${rendered}" '^kind: Deployment$' 1
assert_count_regex "${rendered}" '^kind: NetworkPolicy$' 1
assert_count_regex "${rendered}" '^kind: ServiceAccount$' 1
assert_not_regex "${rendered}" '^kind: Service$' "worker has no Service"
assert_not_contains "${rendered}" 'kind: Ingress' "worker has no ingress"
assert_not_contains "${rendered}" 'kind: SecretProviderClass' "no secrets declared"
# Paused application-runtime: compute at zero while the declaration remains.
assert_contains "${rendered}" 'replicas: 0'
assert_contains "${rendered}" 'platform.yourown.chat/paused: "true"'
assert_contains "${rendered}" 'priorityClassName: development'
assert_contains "${rendered}" 'terminationGracePeriodSeconds: 60'
assert_contains "${rendered}" 'kubernetes.io/metadata.name: "temporal"'
assert_contains "${rendered}" 'cidr: 169.254.169.254/32'
assert_contains "${rendered}" 'prometheus.io/scrape: "true"'
assert_contains "${rendered}" 'AGENT_RESULTS_BUCKET'

# Resume restores the declared replica count.
render "${chart}" worker-valid yourown-agents --set runtime.paused=false > "${running}"
assert_contains "${running}" 'replicas: 1'
assert_contains "${running}" 'platform.yourown.chat/paused: "false"'

# A worker without ports or probes still renders a deny-by-default policy and no probes.
render "${chart}" worker-valid yourown-agents --set-json 'container.ports=[]' --set-json 'container.health={"port":"metrics"}' --set observability.metrics.enabled=false --set-json 'network.ingress=[]' > "${running}"
assert_not_contains "${running}" 'readinessProbe' "no probes without health declaration"
assert_contains "${running}" 'ingress: []'

expect_fail "worker cannot declare ingress" "ingress.*not allowed" "${chart}" worker-valid yourown-agents --set ingress.enabled=true
expect_fail "worker cannot declare a Service" "service.*not allowed" "${chart}" worker-valid yourown-agents --set service.enabled=true
expect_fail "worker cannot declare agent registry" "agentRegistry.*not allowed" "${chart}" worker-valid yourown-agents --set agentRegistry.enabled=true
expect_fail "ingress rule without ports on a portless worker" "needs ports" "${chart}" worker-valid yourown-agents --set-json 'container.ports=[]' --set-json 'container.health={"port":"metrics"}' --set observability.metrics.enabled=false --set-json 'network.ingress=[{"name":"x","purpose":"scrape without ports","from":{"sameNamespace":true}}]'
expect_fail "metrics port not declared" "not declared in container.ports" "${chart}" worker-valid yourown-agents --set observability.metrics.port=http
expect_fail "extra containers" "extraContainers.*not allowed" "${chart}" worker-valid yourown-agents --set-json 'extraContainers=[{"name":"x"}]'

finish
