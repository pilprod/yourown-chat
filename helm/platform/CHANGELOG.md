# Platform workload profiles — change log

Every profile chart follows Semantic Versioning for its public contract (see
[README.md](README.md#versioning-and-publication)). A version is published
once as an immutable OCI artifact in the platform Helm chart repository and is
never rebuilt; a correction is a new version. Entries below record, per
published version, the contract and the migration notes a service wrapper
needs when it pins the version.

## 0.1.0 — 2026-08-23 (first published contract)

Published for `platform-service`, `platform-worker`, `platform-job` and
`platform-stateful` at the same version.

### Contract

- Strict `values.schema.json` per profile (`additionalProperties: false`),
  typed capabilities only; profile identity and resource bounds come from the
  chart's `Chart.yaml` annotations, never from values or per-chart named
  templates.
- Release parameters: `image.digest` (Artifact Registry `repository@sha256`
  only), `identity.googleServiceAccount`, `secrets.project`,
  `network.clusterDNSIP` (required), and for `platform-stateful`
  `layer4Exposure.reservedAddress`.
- Platform-owned rendering: non-root security context with `RuntimeDefault`
  seccomp, dropped capabilities, read-only root filesystem with a bounded
  `/tmp`, `automountServiceAccountToken: false`, `enableServiceLinks: false`,
  one ServiceAccount per workload (Workload Identity annotation), Secret
  Manager CSI (`provider: gke`) from logical references, deny-by-default
  NetworkPolicy with a DNS baseline and typed peers (`sameNamespace`,
  `namespace`, `ingressController`, `cidr`, `internet`, `metadataServer`),
  `ClusterIP`-only Services, platform labels and digest/secret-checksum
  annotations.
- `platform-service`: typed HTTP ingress (nginx class, platform origin TLS
  secret reference, bounded proxy and rate-limit settings), CPU autoscaling,
  disruption budget consistent with the replica model, Agent Registry
  discovery for MCP servers (requires the Service).
- `platform-worker`: no Service, optional metrics port, declared pause and
  scale-to-zero.
- `platform-job`: Job or CronJob with explicit deadline, retry, concurrency
  and cleanup; the Job run name hashes the chart version and every value;
  `workload.name` is bounded to 50 characters.
- `platform-stateful`: StatefulSet with retained volume claims, headless and
  internal Services, and the narrow typed layer-four exposure (one
  `LoadBalancer` Service per protocol on the reserved address, public ingress
  rule limited to the declared ports).
- Bounds: CPU request <= 2000m, CPU limit <= 4000m (optional), memory request
  <= 4Gi, memory limit <= 8Gi (required), strictly positive quantities;
  replicas 0..10 (`platform-stateful` 1..3); container ports 1024..65535.

### Release integration (not part of the published charts)

- Service release manifest (`helm/release.yaml`) and minimal wrappers in the
  owning repositories; `helm/platform/release/assemble.sh` validates wrappers,
  vendors the pinned charts, renders every Cloud Deploy profile with the typed
  release parameters, runs the shared policy check, generates the verification
  Jobs and lifecycle actions, and records release evidence.

### Migration notes

- First publication; no previous contract to migrate from. Wrappers pin
  `0.1.0` from `oci://<location>-docker.pkg.dev/<project>/helm` and commit
  `Chart.lock`.
