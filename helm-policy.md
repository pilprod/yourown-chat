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
