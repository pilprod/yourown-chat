# Helm platform policy

## Ownership

The public platform repository owns reusable platform Helm charts, schemas,
policy tests, and generic build and delivery integration. It does not contain
service-specific release wrappers, component catalogs, repository names,
environment overlays, or application values.

Each service repository owns its source code and a minimal service-specific
Helm release wrapper. The wrapper pins an approved platform chart version and
contains only the service values and environment overlays allowed by the
platform contract.

The public Terraform and delivery implementation remains generic. Private
service names and repository connections are supplied through an approved
private service catalog or private Terraform input rather than being hardcoded
in public source.

## Platform chart requirement

A service must use an approved platform chart. It must not create an
independent Deployment, Service, Ingress, NetworkPolicy, autoscaling,
security-context, secret-mount, or observability implementation from scratch.

Platform templates are not copied into service repositories. A missing
capability is added to the platform chart or implemented through a separately
approved platform workload profile.

A normal service wrapper contains `Chart.yaml`, `Chart.lock`, approved values,
and environment overlays. It contains no copied platform templates or
application source.

## Distribution and adoption

Platform charts are published as immutable versioned OCI artifacts. A service
wrapper pins an exact approved chart version and commits its dependency lock.
Floating chart versions and implicit upgrades are not permitted.

A platform chart update reaches a service through an explicit dependency
change in that service repository, followed by the service's authoritative
tests and dev-to-production delivery lifecycle. A chart publication does not
silently modify a running service.

## Delivery integration

Generic Skaffold and Cloud Deploy integration belongs to the public platform
repository. Service repositories do not create independent deployment
pipelines or use Skaffold as an alternative remote control plane.

Remote rendering, deployment, verification, and promotion follow the approved
MCP and delivery policies. The exact immutable application image and platform
chart inputs are preserved through development and production.

## Workload profiles

Every deployable workload selects the smallest approved platform profile that
matches its controller, network, state, and lifecycle requirements.

The approved standard profiles are:

- `platform-service` for a stateless networked service;
- `platform-worker` for background processing without network exposure by
  default;
- `platform-job` for a bounded Job or CronJob;
- `platform-stateful` for a workload that requires stable identity or retained
  persistent volumes.

A service wrapper does not change the workload kind through arbitrary values.
A new workload profile requires an approved lifecycle, security, scaling, or
failure-isolation reason. A feature name alone does not justify a new chart.

`platform-stateful` is not used to create an application-owned database when
the database belongs to the managed platform data layer.

## Typed extension boundary

Platform charts must not expose unrestricted `rawYaml`, `extraObjects`,
`podSpec`, `extraContainers`, or arbitrary template injection. Required
capabilities are represented by typed, validated platform values.

An operator-managed or vendor-packaged workload may compose an explicitly
approved pinned upstream chart or custom-resource adapter with the platform
security and networking contract. It must not bypass platform policy by
embedding arbitrary manifests in service values.

An approved vendor or operator integration pins the exact dependency version,
passes render and policy verification, and preserves platform identity,
secret, network, observability, and delivery requirements.

## Values contract

Service values describe typed application capabilities rather than
unrestricted Kubernetes implementation. Every platform profile publishes a
strict `values.schema.json` that rejects unknown properties and validates
required fields, types, bounds, and capability combinations.

Within the approved schema, a service may declare its ports, health endpoints,
bounded resource and scaling requirements, non-secret application
configuration, logical secret references, and documented service
dependencies. The platform owns the security context, workload identity,
registry policy, immutable image injection, admission requirements, network
policy, observability integration, and required platform labels.

Remote environments run an immutable image digest supplied by the
authoritative release pipeline. A service wrapper must not select an arbitrary
registry, use a mutable image tag, or replace the release-supplied digest.

The values contract must not expose `podSpec`, `rawYaml`, `extraObjects`,
arbitrary annotations, `hostNetwork`, `hostPID`, privileged mode, arbitrary
service-account selection, cluster-scoped RBAC, plaintext secret environment
variables, or an equivalent policy-bypass surface. A special requirement such
as a multi-protocol load balancer is represented by a narrow typed capability,
not by accepting a raw Kubernetes object.

## Secret delivery

A service value may contain only a logical secret reference and the approved
runtime purpose or mount path. It must never contain the secret value, an
encoded copy of the value, or an unrestricted `SecretProviderClass` fragment.

The default GKE runtime path is Google Secret Manager through the GKE Secret
Manager CSI add-on. The platform renders an approved `SecretProviderClass`
using `provider: gke`, and the workload mounts it read-only through the
`secrets-store-gke.csi.k8s.io` driver. Access uses a dedicated least-privilege
Workload Identity. The secret must remain protected by the platform's approved
Secret Manager encryption and CMEK policy, and it must not be synchronized
into a native Kubernetes Secret merely for application convenience.

A native Kubernetes Secret is permitted only as an explicitly approved
compatibility exception for an application, operator, or vendor interface that
cannot consume a CSI-mounted file. The exception is created by its
authoritative infrastructure owner, is not rendered from Helm values or passed
through the application delivery pipeline, and remains protected by GKE
application-layer Secret encryption for etcd using the approved CMEK. Its
identity, namespace, consumers, and rotation procedure must be documented and
least-privilege scoped.

Secret version selection, refresh, rotation, and restart behavior are owned by
the platform contract. A service wrapper must not bypass that lifecycle by
copying a secret into a ConfigMap, environment overlay, generated manifest,
release parameter, image layer, or application repository.

## Configuration layers

Helm configuration uses one documented precedence order:

1. immutable platform chart defaults;
2. service-owned base values;
3. the service-owned overlay for the target environment;
4. the narrow set of typed release parameters approved by the platform
   contract.

The service repository contains its base values and separate minimal
environment overlays. An overlay records only an intentional difference for
that environment. It must not replace platform templates or change a
platform-owned security context, workload identity, secret driver, registry
policy, network-policy baseline, admission requirement, or observability
control.

Arbitrary command-line `--set` overrides are not a deployment interface.
Release-time values are limited to the schema-defined parameters required by
the delivery lifecycle, such as the verified immutable image digest and an
approved environment-specific reference. Secret values are prohibited from
every configuration layer and release parameter; only approved logical secret
references are permitted.

For every target environment, the authoritative pipeline renders the complete
configuration and validates it against the chart schema and platform policy
before deployment. A configuration that has not passed the applicable render
and policy checks is not eligible for promotion.

Release evidence records the exact platform chart version, service-wrapper
revision, immutable application image digest, environment overlay revision,
approved release parameters, and a reproducible digest of the fully resolved
configuration. Environment-specific configuration may differ only through
the declared overlays and typed parameters; it must not replace the verified
application artifact during promotion.

## Platform chart versioning

Platform charts use Semantic Versioning for their public contract:

- a major version introduces an incompatible schema, rendering, or behavioral
  change;
- a minor version adds a backward-compatible capability;
- a patch version fixes an implementation or security defect without changing
  the supported contract.

Every chart version is published as an immutable OCI artifact. An existing
version must not be overwritten, retagged, or rebuilt with different content.
A security correction is published as a new version rather than replacing a
previous artifact. A chart version identifies the platform contract and does
not include a service or environment name.

Before publication, the chart passes schema validation, deterministic render
tests, platform policy tests, and the applicable tests for every supported
workload profile. Release evidence identifies the source revision, chart
version, OCI digest, test results, and provenance required by the release
policy.

An incompatible change requires an approved migration guide and deprecation
period. It must not be disguised as a minor or patch update, and a patch update
must not silently change a service's declared behavior or required values.

A service adopts a new platform chart through an explicit change to its pinned
dependency and committed `Chart.lock`. The service then completes its own
authoritative tests and dev-to-production lifecycle; publication of the chart
alone does not update a service or a running environment.

## Runtime safety and resources

Platform profiles enforce secure container defaults: the process runs as a
non-root user, privilege escalation is disabled, the default seccomp profile
is `RuntimeDefault`, unnecessary Linux capabilities are dropped, and the root
filesystem is read-only. Writable paths are provided only through typed,
bounded ephemeral-volume or persistent-volume capabilities.

A remotely deployed network service has readiness and liveness probes. A
workload with a slow or dependency-sensitive startup also has a startup probe.
The service declares the approved health endpoint or command, while the
platform profile constrains probe behavior and prevents a normal service
overlay from silently disabling required health checks. A bounded Job uses its
completion status rather than artificial service probes.

Every remotely deployed workload declares resource requests. Requests and
applicable resource ceilings remain within profile-defined schema bounds and
are based on measured consumption, startup behavior, concurrency, and
documented safety headroom. A large generic default must not be copied to a
low-usage workload without evidence; resource values are tuned for the
workload profile and verified under representative load.

Service values must not create arbitrary or effectively unbounded resource
allocations. A profile documents any deliberate platform-level exception,
such as CPU-limit behavior for a latency-sensitive workload, and verifies the
result through load and failure testing.

Replica counts, autoscaling, rollout strategy, and disruption budgets must be
internally consistent. A disruption budget must not prevent maintenance of a
single-replica workload, and a single replica must not be represented as highly
available. Scaling to zero follows the component's approved operational class
and pause lifecycle rather than an ad hoc deployment override.

The platform profile provides graceful termination and a termination period
appropriate to the workload type. A workload drains or stops accepting new
work before exit when its protocol and responsibility require it.

A service-specific values file cannot weaken these controls. A necessary
exception requires an explicitly approved platform profile or vendor adapter,
a documented reason and scope, and verification of the resulting security,
reliability, and resource behavior.

## Network exposure

A workload is private by default and receives only an internal `ClusterIP`
Service when network discovery is required. Public ingress, direct load
balancing, node-level ports, and host networking are disabled unless the
selected platform capability explicitly requires them.

HTTP exposure uses the approved typed platform ingress capability and the
platform-managed edge, DNS, and TLS controls. A service wrapper declares an
approved host and application port through the schema; it must not provide a
raw Ingress, arbitrary controller annotations, certificates, or an alternate
edge implementation.

Direct layer-four exposure is permitted only for a protocol that cannot be
correctly carried through the approved application edge. It uses a dedicated
Service or load balancer, an exact TCP or UDP port set, and selectors that
target only the approved transport workload. It must not expose unrelated
workloads, internal control APIs, cluster administration, or the cluster as a
whole.

Service values must not select arbitrary external addresses, load-balancer
annotations, `NodePort`, `hostNetwork`, `hostPort`, or an equivalent path around
the platform networking contract. A required transport exception is expressed
as a narrow typed platform profile or adapter and receives a separate threat
and blast-radius review.

The platform chart creates deny-by-default ingress and egress policy for every
workload profile. Each allow rule identifies the exact source, destination,
port, protocol, and purpose. Public transport traffic, private service traffic,
control-plane traffic, and administrative traffic remain separate policy
paths.

A public transport endpoint must not publish its associated internal control
or management endpoint. Sensitive integration and automation services remain
internal or are reached only through an explicitly approved authenticated
gateway or tunnel; they are not exposed merely because another workload needs
public network traffic.

The public platform policy defines these generic capabilities without naming
private components. Approved component assignments, direct-transport
exceptions, and gateway or tunnel mappings are maintained in the private
repository map and cannot weaken this baseline.
