#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

chart=platform-service
rendered="$(mktemp)"; second="$(mktemp)"; edge="$(mktemp)"
trap 'rm -f "${rendered}" "${second}" "${edge}"' EXIT

render "${chart}" service-valid identity > "${rendered}"
render "${chart}" service-valid identity > "${second}"
cmp -s "${rendered}" "${second}" || { echo "FAIL: render is not deterministic" >&2; failures=$((failures + 1)); }
assert_platform_invariants "${rendered}"
golden "${rendered}" service-valid

# Rendered topology.
assert_count_regex "${rendered}" '^kind: Deployment$' 1
assert_count_regex "${rendered}" '^kind: Service$' 1
assert_count_regex "${rendered}" '^kind: NetworkPolicy$' 1
assert_count_regex "${rendered}" '^kind: PodDisruptionBudget$' 1
assert_count_regex "${rendered}" '^kind: SecretProviderClass$' 1
assert_count_regex "${rendered}" '^kind: ServiceAccount$' 1
assert_not_contains "${rendered}" 'kind: Ingress' "ingress disabled by default"
assert_not_contains "${rendered}" 'kind: HorizontalPodAutoscaler' "autoscaling disabled by default"
assert_contains "${rendered}" 'type: ClusterIP'
assert_contains "${rendered}" 'replicas: 2'
assert_contains "${rendered}" 'minAvailable: 1'
assert_contains "${rendered}" 'iam.gke.io/gcp-service-account: "identity-api@example-project.iam.gserviceaccount.com"'
assert_contains "${rendered}" 'provider: gke'
assert_contains "${rendered}" 'resourceName: "projects/example-project/secrets/yourown-chat-identity-runtime-database-url/versions/latest"'
assert_contains "${rendered}" 'driver: secrets-store-gke.csi.k8s.io'
assert_contains "${rendered}" 'mountPath: /var/run/secrets/app'
assert_contains "${rendered}" 'kubernetes.io/metadata.name: "edge"'
assert_contains "${rendered}" 'cidr: "10.20.30.40/32"'
assert_contains "${rendered}" 'cidr: "10.30.0.10/32"'
assert_contains "${rendered}" 'prometheus.io/port: "9464"'
assert_contains "${rendered}" 'priorityClassName: production'
assert_contains "${rendered}" 'image-digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
assert_contains "${rendered}" 'app.kubernetes.io/part-of: yourown-chat-server'
assert_not_contains "${rendered}" '"0.0.0.0/0"' "no public ingress on a private service"

# Typed HTTP ingress renders only the approved edge capability and opens the
# matching NetworkPolicy path from the ingress controller.
render "${chart}" service-valid edge \
  --set ingress.enabled=true \
  --set ingress.host=api.example.test \
  --set ingress.originTLSSecret=origin-tls \
  --set-json 'ingress.paths=[{"path":"/transport/v1","pathType":"Exact"}]' \
  --set ingress.rateLimit.enabled=true > "${edge}"
assert_contains "${edge}" 'kind: Ingress'
assert_contains "${edge}" 'ingressClassName: nginx'
assert_contains "${edge}" 'host: "api.example.test"'
assert_contains "${edge}" 'secretName: origin-tls'
assert_contains "${edge}" 'pathType: Exact'
assert_contains "${edge}" 'nginx.ingress.kubernetes.io/limit-rps: "10"'
assert_contains "${edge}" 'nginx.ingress.kubernetes.io/enable-access-log: "false"'
assert_contains "${edge}" 'kubernetes.io/metadata.name: ingress-nginx'
assert_not_contains "${edge}" 'certificate' "no certificate material"

# Pause keeps the declaration while scaling compute to zero.
render "${chart}" service-valid identity --set runtime.paused=true --set runtime.disruptionBudget.enabled=false > "${edge}"
assert_contains "${edge}" 'replicas: 0'
assert_contains "${edge}" 'platform.yourown.chat/paused: "true"'

# Autoscaling removes the static replica count and renders an HPA.
render "${chart}" service-valid identity --set runtime.autoscaling.enabled=true --set runtime.autoscaling.minReplicas=2 > "${edge}"
assert_contains "${edge}" 'kind: HorizontalPodAutoscaler'
assert_not_contains "${edge}" 'replicas: 2' "static replicas removed when autoscaling"

# Agent Registry discovery is a narrow typed capability.
render "${chart}" service-valid identity --set agentRegistry.enabled=true > "${edge}"
assert_contains "${edge}" 'registry.gke.io/functional-type: "MCP_SERVER"'
assert_contains "${edge}" 'iam.gke.io/spiffe-identity-type: agent-identity'
assert_contains "${edge}" 'http://identity-api.identity.svc.cluster.local:8081/mcp'

# Policy tests: the contract rejects bypass surfaces and inconsistent values.
expect_fail "unknown top-level key podSpec" "podSpec.*not allowed" "${chart}" service-valid identity --set-json 'podSpec={"hostNetwork":true}'
expect_fail "rawYaml injection" "rawYaml.*not allowed" "${chart}" service-valid identity --set-json 'rawYaml=["kind: Pod"]'
expect_fail "host networking" "hostNetwork.*not allowed" "${chart}" service-valid identity --set container.hostNetwork=true
expect_fail "layer-four exposure on a service profile" "layer4Exposure.*not allowed" "${chart}" service-valid identity --set layer4Exposure.enabled=true
expect_fail "arbitrary Service type" "type.*not allowed" "${chart}" service-valid identity --set service.type=LoadBalancer
expect_fail "mutable image tag" "image/digest|image\.digest" "${chart}" service-valid identity --set image.digest=europe-west3-docker.pkg.dev/example-project/docker/app:1.2.3
expect_fail "foreign registry" "image/digest|image\.digest" "${chart}" service-valid identity --set image.digest=docker.io/library/nginx@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
expect_fail "privileged port" "container/ports/0/port|container\.ports\.0\.port" "${chart}" service-valid identity --set 'container.ports[0].port=80'
expect_fail "plaintext secret environment" "looks like a plaintext secret" "${chart}" service-valid identity --set container.env.APP_TOKEN=""
expect_fail "secret mount without Workload Identity" "requires identity.googleServiceAccount" "${chart}" service-valid identity --set identity.googleServiceAccount=""
expect_fail "secret mount without project" "requires secrets.project" "${chart}" service-valid identity --set secrets.project=""
expect_fail "disruption budget on a single replica" "requires at least two replicas" "${chart}" service-valid identity --set runtime.replicas=1
expect_fail "disruption budget blocking maintenance" "must be lower than the minimum replica count" "${chart}" service-valid identity --set runtime.disruptionBudget.minAvailable=2
expect_fail "ingress without origin TLS reference" "/ingress|ingress\." "${chart}" service-valid identity --set ingress.enabled=true --set ingress.host=api.example.test --set-json 'ingress.paths=[{"path":"/","pathType":"Prefix"}]'
expect_fail "ingress without paths" "/ingress|ingress\." "${chart}" service-valid identity --set ingress.enabled=true --set ingress.host=api.example.test --set ingress.originTLSSecret=origin-tls
expect_fail "ingress on an undeclared port" "not declared in container.ports" "${chart}" service-valid identity --set ingress.enabled=true --set ingress.host=api.example.test --set ingress.originTLSSecret=origin-tls --set ingress.port=grpc --set-json 'ingress.paths=[{"path":"/","pathType":"Prefix"}]'
expect_fail "egress rule without purpose" "missing property 'purpose'|purpose is required" "${chart}" service-valid identity --set-json 'network.egress=[{"name":"x","to":{"cidr":"10.0.0.1/32"},"ports":[{"port":443}]}]'
expect_fail "egress rule with two peer kinds" "network/egress/0/to|network\.egress\.0\.to" "${chart}" service-valid identity --set-json 'network.egress=[{"name":"x","purpose":"two peers at once","to":{"cidr":"10.0.0.1/32","namespace":"mattermost"},"ports":[{"port":443}]}]'
expect_fail "egress rule without ports" "missing property 'ports'|ports is required" "${chart}" service-valid identity --set-json 'network.egress=[{"name":"x","purpose":"open egress","to":{"internet":true}}]'
expect_fail "memory request above limit" "must not exceed container.resources.limits.memory" "${chart}" service-valid identity --set container.resources.requests.memory=512Mi
expect_fail "CPU request above the profile bound" "exceeds the platform-service profile bound" "${chart}" service-valid identity --set container.resources.requests.cpu=3000m --set container.resources.limits.cpu=""
expect_fail "memory limit above the profile bound" "exceeds the platform-service profile bound" "${chart}" service-valid identity --set container.resources.limits.memory=16Gi
expect_fail "missing memory limit" "container/resources/limits/memory|container\.resources\.limits\.memory" "${chart}" service-valid identity --set-json 'container.resources.limits={"cpu":"250m"}'
expect_fail "replica count above bound" "runtime/replicas|runtime\.replicas" "${chart}" service-valid identity --set runtime.replicas=11
expect_fail "autoscaling minimum above maximum" "minReplicas must not exceed maxReplicas" "${chart}" service-valid identity --set runtime.autoscaling.enabled=true --set runtime.autoscaling.minReplicas=5 --set runtime.autoscaling.maxReplicas=2
expect_fail "readiness probe without endpoint" "requires container.health.readiness and container.health.liveness" "${chart}" service-valid identity --set-json 'container.health.readiness={"periodSeconds":10,"timeoutSeconds":3,"failureThreshold":3}'
expect_fail "probe with both httpGet and exec" "container/health/liveness|container\.health\.liveness" "${chart}" service-valid identity --set-json 'container.health.liveness={"httpGet":{"path":"/healthz"},"exec":{"command":["true"]},"periodSeconds":10,"timeoutSeconds":3,"failureThreshold":3}'
expect_fail "health port not declared" "not declared in container.ports" "${chart}" service-valid identity --set container.health.port=grpc
expect_fail "writable volume over a reserved path" "writableVolumes" "${chart}" service-valid identity --set-json 'container.writableVolumes=[{"name":"etc","mountPath":"/etc","sizeLimit":"8Mi"}]'
expect_fail "global values are not part of the contract" "global" "${chart}" service-valid identity --set global.registry=docker.io
expect_fail "unapproved priority class" "priorityClass" "${chart}" service-valid identity --set runtime.priorityClass=system-cluster-critical
expect_fail "unknown workload name shape" "workload/name|workload\.name" "${chart}" service-valid identity --set workload.name=Identity_API
expect_fail "secret version must be latest or a number" "secrets/files/0/version|secrets\.files\.0\.version" "${chart}" service-valid identity --set 'secrets.files[0].version=newest'

finish
