#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

chart=platform-stateful
rendered="$(mktemp)"; second="$(mktemp)"; private="$(mktemp)"
trap 'rm -f "${rendered}" "${second}" "${private}"' EXIT

render "${chart}" stateful-valid mattermost-rtcd > "${rendered}"
render "${chart}" stateful-valid mattermost-rtcd > "${second}"
cmp -s "${rendered}" "${second}" || { echo "FAIL: render is not deterministic" >&2; failures=$((failures + 1)); }
assert_platform_invariants "${rendered}"
golden "${rendered}" stateful-valid

assert_count_regex "${rendered}" '^kind: StatefulSet$' 1
assert_count_regex "${rendered}" '^kind: Service$' 4
assert_count "${rendered}" 'type: LoadBalancer' 2
assert_count "${rendered}" 'cloud.google.com/l4-rbs: "enabled"' 2
assert_count "${rendered}" 'loadBalancerIP: "203.0.113.10"' 2
assert_contains "${rendered}" 'externalTrafficPolicy: Local'
assert_contains "${rendered}" 'clusterIP: None'
assert_contains "${rendered}" 'serviceName: rtcd-headless'
assert_contains "${rendered}" 'whenDeleted: Retain'
assert_contains "${rendered}" 'whenScaled: Retain'
assert_contains "${rendered}" 'storageClassName: "rtcd-cmek"'
assert_contains "${rendered}" 'storage: 1Gi'
assert_contains "${rendered}" 'mountPath: /var/lib/rtcd'
assert_contains "${rendered}" 'fsGroupChangePolicy: OnRootMismatch'
assert_contains "${rendered}" 'terminationGracePeriodSeconds: 300'
assert_contains "${rendered}" 'pool: "general"'
# Public transport is limited to the exact TCP/UDP port set; the API stays private.
assert_contains "${rendered}" 'cidr: "0.0.0.0/0"'
assert_contains "${rendered}" 'kubernetes.io/metadata.name: "mattermost"'
tcp_service="$(awk 'BEGIN { RS="---" } /name: rtcd-tcp/ { print }' "${rendered}")"
udp_service="$(awk 'BEGIN { RS="---" } /name: rtcd-udp/ { print }' "${rendered}")"
grep -Fq 'port: 8045' <<<"${tcp_service}" && { echo "FAIL: API port published on the TCP load balancer" >&2; failures=$((failures + 1)); }
grep -Fq 'protocol: TCP' <<<"${udp_service}" && { echo "FAIL: TCP port published on the UDP load balancer" >&2; failures=$((failures + 1)); }
public_rule="$(awk '/# public-transport:/ { capture = 1 } /^  egress:/ { capture = 0 } capture { print }' "${rendered}")"
grep -Fq 'port: 8045' <<<"${public_rule}" && { echo "FAIL: public transport rule must not open the API port" >&2; failures=$((failures + 1)); }
internal_service="$(awk 'BEGIN { RS="---" } /kind: Service\n/ && /  name: rtcd\n/ { print }' "${rendered}")"
grep -Fq 'type: ClusterIP' <<<"${internal_service}" || { echo "FAIL: API Service must stay ClusterIP" >&2; failures=$((failures + 1)); }
grep -Fq 'port: 8443' <<<"${internal_service}" && { echo "FAIL: transport ports must not appear on the internal Service" >&2; failures=$((failures + 1)); }

# Without layer-four exposure the workload is private by default.
render "${chart}" stateful-valid mattermost-rtcd --set layer4Exposure.enabled=false --set-json 'network.egress=[]' > "${private}"
assert_not_contains "${private}" 'type: LoadBalancer' "no load balancer by default"
assert_not_contains "${private}" '0.0.0.0/0' "no public ingress by default"
assert_count_regex "${private}" '^kind: Service$' 2

expect_fail "layer-four exposure without reserved address" "layer4Exposure" "${chart}" stateful-valid mattermost-rtcd --set layer4Exposure.reservedAddress=""
expect_fail "layer-four port not declared on the container" "not declared in container.ports" "${chart}" stateful-valid mattermost-rtcd --set-json 'layer4Exposure.ports=[{"name":"admin","port":9000,"protocol":"TCP"}]'
expect_fail "layer-four protocol mismatch" "must use the same protocol" "${chart}" stateful-valid mattermost-rtcd --set-json 'layer4Exposure.ports=[{"name":"rtc-tcp","port":8443,"protocol":"UDP"}]'
expect_fail "layer-four port number mismatch" "must use the same port number" "${chart}" stateful-valid mattermost-rtcd --set-json 'layer4Exposure.ports=[{"name":"rtc-tcp","port":9443,"protocol":"TCP"}]'
expect_fail "replicas above the stateful bound" "runtime/replicas|runtime\.replicas" "${chart}" stateful-valid mattermost-rtcd --set runtime.replicas=4
expect_fail "stateful has no HTTP ingress" "ingress.*not allowed" "${chart}" stateful-valid mattermost-rtcd --set ingress.enabled=true
expect_fail "stateful has no autoscaling" "autoscaling.*not allowed" "${chart}" stateful-valid mattermost-rtcd --set runtime.autoscaling.enabled=true
expect_fail "persistence over a reserved path" "persistence" "${chart}" stateful-valid mattermost-rtcd --set persistence.mountPath=/tmp
expect_fail "unsupported access mode" "accessMode" "${chart}" stateful-valid mattermost-rtcd --set persistence.accessMode=ReadWriteMany
expect_fail "cluster traffic policy" "externalTrafficPolicy" "${chart}" stateful-valid mattermost-rtcd --set layer4Exposure.externalTrafficPolicy=Cluster
expect_fail "disruption budget on a single replica" "requires at least two replicas" "${chart}" stateful-valid mattermost-rtcd --set runtime.disruptionBudget.enabled=true

finish
