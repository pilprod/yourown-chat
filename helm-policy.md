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
