# Platform workload profiles

This directory is the authoritative source of the reusable YourOwn.Chat
platform Helm charts required by the public
[Helm platform policy](../../.ai/helm-policy.md). Each chart is one approved
workload profile. A service repository does not copy these templates; it owns a
minimal release wrapper that pins an exact published profile version and
supplies only schema-validated values.

| Profile | Use for | Renders |
|---|---|---|
| `platform-service` | A stateless networked service | Deployment, ClusterIP Service, deny-by-default NetworkPolicy, ServiceAccount, optional SecretProviderClass, optional typed HTTP ingress, HorizontalPodAutoscaler, PodDisruptionBudget |
| `platform-worker` | Background processing without network exposure by default | Deployment, deny-by-default NetworkPolicy, ServiceAccount, optional SecretProviderClass, HorizontalPodAutoscaler, PodDisruptionBudget; supports declared pause and scale-to-zero |
| `platform-job` | A bounded Job or CronJob (migration, maintenance) | Job or CronJob with explicit deadline, retry, concurrency and cleanup, deny-by-default NetworkPolicy, ServiceAccount, optional SecretProviderClass |
| `platform-stateful` | A workload requiring stable identity or retained persistent volumes | StatefulSet with retained claims, headless and ClusterIP Services, deny-by-default NetworkPolicy, ServiceAccount, optional SecretProviderClass, PodDisruptionBudget, and only when explicitly enabled the narrow typed layer-four transport exposure |

A feature name alone never justifies a new profile. A missing capability is
added here as a typed, validated value and released as a new chart version.

## Consumption model

A service wrapper contains `Chart.yaml`, `Chart.lock`, base values and minimal
environment overlays. It pins one exact profile version per workload and may
alias the same profile several times:

```yaml
# <service repository>/helm/<wrapper>/Chart.yaml
apiVersion: v2
name: identity
version: 1.0.0
dependencies:
  - name: platform-service
    version: 0.1.0            # exact published version; no ranges
    repository: oci://<platform chart registry>
    alias: identity-api
  - name: platform-job
    version: 0.1.0
    repository: oci://<platform chart registry>
    alias: identity-migrate
```

```yaml
# <service repository>/helm/<wrapper>/values.yaml
identity-api:
  workload: { name: identity-api, partOf: identity }
  container:
    ports: [{ name: http, port: 8081 }]
    health:
      readiness: { httpGet: { path: /readyz } }
      liveness: { httpGet: { path: /healthz } }
    resources:
      requests: { cpu: 5m, memory: 16Mi }
      limits: { cpu: 250m, memory: 256Mi }
  secrets:
    files: [{ secret: yourown-chat-identity-runtime-database-url, file: database-url }]
  network:
    ingress:
      - name: from-transport
        purpose: Transport gateway forwards authenticated identity requests
        from: { namespace: edge, podLabels: { app: transport } }
    egress:
      - name: cloudsql
        purpose: PostgreSQL on the private Cloud SQL address
        to: { cidr: 10.20.30.40/32 }
        ports: [{ port: 5432 }]
```

Helm validates the values of every aliased dependency against that profile's
`values.schema.json`. Optional workloads are switched with parent-chart
`tags`, not with an extra key inside the profile values.

The profile charts are deliberately **not renderable without wrapper values**:
`workload.name`, `image.digest`, ports, probes and resources are required, so a
bare `helm template` or `helm lint` of a profile fails by design. Lint and render
them with representative values as the tests do.

### Release parameters

These values are supplied by the authoritative release pipeline as typed
release-time parameters and are not hand-maintained in a service overlay:

| Value | Meaning |
|---|---|
| `image.digest` | Artifact Registry `repository@sha256:` reference of the verified immutable image. Tags and foreign registries are rejected. |
| `identity.googleServiceAccount` | Dedicated Workload Identity service account e-mail bound to the workload ServiceAccount. Required whenever secrets are mounted. |
| `secrets.project` | Google Cloud project that owns the referenced Secret Manager secrets. |
| `network.clusterDNSIP` | Optional cluster DNS address added to the DNS egress baseline. |
| `layer4Exposure.reservedAddress` (`platform-stateful`) | Platform-reserved address of the dedicated layer-four load balancer. |

Everything else in a profile's `values.yaml` is a service-owned, typed
capability. Arbitrary `--set` overrides are not a deployment interface.

## Platform-owned controls

The profiles render the following without exposing them as values: non-root
`runAsUser`/`runAsGroup`/`fsGroup` (default 65532, bounded override through
`container.runAsUser`), `RuntimeDefault` seccomp, dropped capabilities, no
privilege escalation, read-only root filesystem with `/tmp` as a bounded
ephemeral volume, `automountServiceAccountToken: false`,
`enableServiceLinks: false`, one ServiceAccount per workload, the Secret Manager
CSI driver (`provider: gke`, read-only mount), deny-by-default ingress and
egress policy with a DNS baseline, `ClusterIP`-only Services, the nginx ingress
class with the platform origin TLS secret reference, platform labels
(`app.kubernetes.io/*`, `platform.yourown.chat/profile`,
`platform.yourown.chat/chart-version`), image-digest and secret-checksum pod
annotations, and priority classes limited to `development` and `production`.

The schemas reject `podSpec`, `rawYaml`, `extraObjects`, `extraContainers`,
`initContainers`, `hostNetwork`, `hostPID`, `hostPort`, `privileged`, raw
`nodeSelector`/`tolerations`/`affinity`, arbitrary annotations, arbitrary
`serviceAccountName`, `imagePullSecrets`, `securityContext`, raw `volumes`,
native `Secret` rendering, plaintext secret environment variables, `NodePort`,
`LoadBalancer` on non-transport profiles and every unknown property.
`helm/test/platform-common.test.sh` enforces this boundary on every schema.

### Profile bounds

| Bound | Value |
|---|---|
| CPU request | <= 2000m |
| CPU limit (optional, documented exception when omitted) | <= 4000m |
| Memory request | <= 4Gi |
| Memory limit (required) | <= 8Gi |
| Replicas | `platform-service`/`platform-worker` 0..10, `platform-stateful` 1..3 |
| Container ports | 1024..65535 |
| Termination grace period | 1..600 s (`platform-stateful` default 300 s) |

Requests must not exceed limits. A PodDisruptionBudget requires at least two
replicas and must leave room for maintenance. `runtime.paused: true` declares
the application-runtime pause state: compute scales to zero while the approved
digest and configuration remain declared.

## Network model

Each profile renders one NetworkPolicy that selects only its workload with
`policyTypes: [Ingress, Egress]`. Without declared rules the workload accepts
no inbound traffic and may only resolve DNS. Every allow rule has a `name`, a
`purpose` and exactly one typed peer:

- ingress peers: `sameNamespace`, `namespace` (+ optional `podLabels`),
  `ingressController`, `cidr`;
- egress peers: `sameNamespace`, `namespace` (+ optional `podLabels`), `cidr`,
  `internet` (public addresses only, RFC 1918 and link-local excluded),
  `metadataServer` (Workload Identity token exchange).

Enabling the typed HTTP ingress automatically adds the rule from the platform
ingress controller to the ingress port. Enabling `layer4Exposure` on
`platform-stateful` adds a separate `public-transport` rule for exactly the
declared TCP/UDP ports, renders one `LoadBalancer` Service per protocol on the
reserved address, and keeps every other declared port on the internal
`ClusterIP` Service. The namespace-wide deny baseline belongs to namespace
bootstrap, not to a workload chart.

## Secrets

`secrets.files` carries only logical Secret Manager references and file names.
The profile renders the `SecretProviderClass` and mounts it read-only under
`secrets.mountPath` (default `/var/run/secrets/app`). Applications read the
mounted file; environment variables that look like secret material are
rejected. Secret version selection defaults to `latest`; pinning a version is a
typed value, rotation and restart behaviour follow the platform contract.

## Shared helpers and generated copies

`_common/_platform.tpl` is the canonical helper source. Every
`platform-*/templates/_platform.tpl` is a generated copy so that each profile is
a self-contained, independently publishable chart. Edit the source, run
`bash helm/platform/sync-common.sh`, and commit both; the common test fails on
drift. Profile-specific resource bounds live in `templates/_bounds.tpl` and are
not overridable through values.

## Versioning and publication

Every profile follows Semantic Versioning for its public contract: a major
version for an incompatible schema, rendering or behavioural change; a minor
version for a backward-compatible capability; a patch version for an
implementation or security fix that does not change the contract. A version is
published once as an immutable OCI artifact and never rebuilt or retagged; a
correction is a new version. A service adopts a new version only through an
explicit change to its pinned dependency and committed `Chart.lock`, followed by
its own tests and dev-to-production lifecycle.

Publication of these charts to the platform Artifact Registry chart repository
is a serialized release action owned by the platform release pipeline and is not
performed from a local machine.

## Tests

```bash
bash helm/test/platform.test.sh
```

runs, for every profile: helper drift check, schema strictness and
policy-bypass boundary, lint with representative values, deterministic render,
golden snapshot comparison (`helm/test/golden/platform`, regenerate with
`UPDATE_GOLDEN=1`), platform invariants, and the negative policy cases that the
contract must reject.
