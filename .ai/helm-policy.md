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

