# Helm platform contract

This document explains how the public
[Helm platform policy](../.ai/helm-policy.md) is implemented in this
repository and how service repositories consume it. The policy is normative;
this page is the operating description. If they disagree, the policy wins and
this page is corrected.

Status: phase 1. The platform profile charts live under `helm/platform/`
(added by the parallel platform-profiles work), the publication rail is
declared in `terraform/app-gcp/modules/chart-publish`, and the existing
service-specific charts under `helm/` remain transitional until each owning
repository adopts a wrapper. Nothing in this phase changes a running
environment.

## Ownership

| Concern | Owner | Location |
|---|---|---|
| Reusable platform profile charts, their `values.schema.json`, render and policy tests | `pilprod/yourown-chat` | `helm/platform/`, `helm/test/platform-*.test.sh` |
| Chart publication rail (identity, registry binding, canonical-branch trigger) | `pilprod/yourown-chat` | `terraform/app-gcp/modules/chart-publish` |
| Generic Skaffold and Cloud Deploy integration | `pilprod/yourown-chat` | `helm/skaffold-*.yaml`, `terraform/app-gcp` |
| Service release wrapper: `Chart.yaml`, `Chart.lock`, base values, environment overlays | The owning service repository listed in [REPOSITORIES.md](REPOSITORIES.md) | that repository |
| Component-to-profile assignments, direct-transport exceptions, tunnel mappings | Private repository map | `pilprod/yourown-chat-rules` |

The public platform repository does not contain a service catalog, service
names, environment overlays, or application values. Private component names
reach a render only through the owning service wrapper or an approved private
Terraform input.

## Profiles

Every deployable workload selects the smallest approved profile:

| Profile | Controller | Use |
|---|---|---|
| `platform-service` | Deployment + ClusterIP Service | stateless networked service; typed HTTP ingress on request |
| `platform-worker` | Deployment, no Service | background processing without network exposure by default |
| `platform-job` | Job or CronJob | bounded run with explicit deadline, retry, concurrency and cleanup |
| `platform-stateful` | StatefulSet + retained volume claims | stable identity or retained persistent volumes; narrow typed layer-four transport on request |

A wrapper cannot change the workload kind through values. A new profile
requires an approved lifecycle, security, scaling, or failure-isolation reason
and an owner decision. `platform-stateful` is not used to create an
application-owned database where the managed platform data layer owns it.

Operator- or vendor-packaged workloads compose an explicitly approved pinned
upstream chart or custom-resource adapter with the platform security and
networking contract; they do not embed raw manifests in service values.

## Values contract

The authoritative contract of each profile is its strict
`values.schema.json`: unknown properties are rejected and required fields,
types, bounds and capability combinations are validated at render time.
Discover the contract from the published artifact rather than from a copy:

```bash
helm show values oci://<location>-docker.pkg.dev/<project>/<helm-repository>/platform-service --version <x.y.z>
```

Service values describe typed application capabilities:

- ports, health endpoints or commands, startup behaviour;
- bounded resource requests and ceilings, replica and autoscaling bounds,
  disruption budget and graceful-termination expectations;
- non-secret application configuration;
- logical secret references (secret identifier and runtime purpose or mount
  path), never a value;
- documented service dependencies expressed as exact network allow rules;
- typed ingress (approved host and application port) for `platform-service`;
- typed multi-protocol layer-four transport for the approved stateful
  exception;
- the operational controls `enabled` (provisioned or not) and `paused`
  (provisioned compute running or scaled to zero).

The platform owns and renders: pod and container security context (non-root,
no privilege escalation, `RuntimeDefault` seccomp, dropped capabilities,
read-only root filesystem, typed writable volumes only), Workload Identity
binding, registry policy and immutable image injection, admission
requirements, deny-by-default network policy with DNS, observability
integration and required platform labels.

Not representable in any profile: `podSpec`, `rawYaml`, `extraObjects`,
`extraContainers`, arbitrary annotations or template injection, `hostNetwork`,
`hostPID`, `hostPort`, `NodePort`, privileged mode, arbitrary service-account
selection, cluster-scoped RBAC, mutable image tags, arbitrary registries,
plaintext secret environment variables, or an unrestricted
`SecretProviderClass` fragment. A special requirement is represented by a
narrow typed capability after a threat and blast-radius review, not by
accepting a raw object.

## Configuration layers

One precedence order applies to every render:

1. immutable platform chart defaults;
2. service-owned base values;
3. the service-owned overlay for the target environment;
4. the narrow set of typed release parameters approved by the platform
   contract (for example the verified immutable image digest, the Workload
   Identity service account, an approved environment-specific reference).

An overlay records only an intentional difference for that environment. It
cannot replace platform templates or change a platform-owned control.
Arbitrary `--set` overrides are not a deployment interface: release-time values
are limited to the schema-defined parameters. Secret values are prohibited from
every layer.

For every target environment the authoritative pipeline renders the complete
configuration and validates it against the chart schema and platform policy
before deployment. Release evidence records the platform chart version, the
service-wrapper revision, the immutable application image digest, the overlay
revision, the approved release parameters and a reproducible digest of the
fully resolved configuration.

## Secret delivery

A service value contains only a logical secret reference and the approved
runtime purpose or mount path. The default runtime path is Google Secret
Manager through the GKE Secret Manager CSI add-on: the platform renders the
`SecretProviderClass` (`provider: gke`), the workload mounts it read-only
through `secrets-store-gke.csi.k8s.io` under a dedicated least-privilege
Workload Identity, and the secret stays protected by the approved Secret
Manager encryption and CMEK policy. Secrets are not synchronised into native
Kubernetes Secrets for convenience.

A native Kubernetes Secret exists only as an explicitly approved compatibility
exception created by its infrastructure owner outside Helm values and the
application delivery pipeline (see the Mattermost operator inputs managed by
`app-gcp`).

## Network exposure

Workloads are private by default. Public HTTP exposure uses the typed platform
ingress capability and the platform-managed edge, DNS and TLS controls. Direct
layer-four exposure exists only for a protocol the application edge cannot
carry correctly, through a dedicated Service with an exact TCP/UDP port set and
selectors targeting only the approved transport workload. Every profile renders
deny-by-default ingress and egress policy; each allow rule identifies the exact
source, destination, port, protocol and purpose. Public transport, private
service, control-plane and administrative traffic remain separate policy
paths. Approved component assignments and exceptions are maintained in the
private repository map.

## Versioning and publication

Platform charts use Semantic Versioning for their public contract:

- **major** — incompatible schema, rendering or behavioural change (requires
  an approved migration guide and deprecation period);
- **minor** — backward-compatible capability;
- **patch** — implementation or security fix without contract change.

A version identifies the platform contract only; it never includes a service
or environment name. Every version is published exactly once as an immutable
OCI artifact and is never overwritten, retagged or rebuilt. A security
correction is a new version.

Publication is performed by the `platform-chart-publish` Cloud Build trigger
declared in `terraform/app-gcp/modules/chart-publish` and wired as the
`chart_publish` component of the `app-gcp` Stack:

- runs only for pushes to the canonical branch that touch `helm/platform/**`
  or `helm/test/platform-*.test.sh`;
- publishes into the dedicated immutable-tag Helm chart repository that
  `platform-gcp` owns and publishes to `app-gcp` (`helm_registry_repository_id`);
  the whole rail stays unmaterialized until that repository exists;
- runs as the dedicated `chart-publish` identity with a repo-scoped writer
  binding on that chart repository (never the image repository) and a
  create-only binding on the evidence bucket, nothing else;
- uses a digest-pinned Helm 3 image and a digest-pinned Google Cloud CLI
  image; no static credential is involved;
- discovers every `helm/platform/*/Chart.yaml` (helper directories without a
  `Chart.yaml`, such as `_common`, are not charts), builds sibling `file://`
  dependencies when a chart declares any (remote chart dependencies are
  rejected), runs `helm lint --strict` for every chart, then runs every
  `helm/test/platform-*.test.sh` (deterministic render, schema negative and
  policy tests); a chart tree with no matching test script fails the build
  because lint does not replace the mandated gates;
- packages each application chart and decides against the registry, not
  against Git history: a version that is not yet present at
  `oci://<location>-docker.pkg.dev/<project>/<helm-repository>/<chart>` is
  pushed; a version that is already present is pulled and compared file by
  file with the packaged source (dependency archives expanded) — identical
  content is recorded as already published so an interrupted build can be
  retried, different content fails the build: bump `Chart.yaml` `version`.
  Library charts are bundled into their dependents and are not published
  separately;
- writes one evidence object per chart version (source revision, build ID,
  chart name and version, publication state, OCI digest, package SHA-256,
  Helm version, lint and test outcome) to the dedicated `chart-evidence`
  bucket — versioned, never expired by lifecycle, create-only for the
  publisher — and to the build log.

Feature branches are verified by review and the same local checks; they never
publish. The trigger does not create a Cloud Deploy release and deploys
nothing. Inspect builds, images and evidence through the approved Google Cloud
MCP; local `gcloud` or `docker` are not an inspection path.

Before the trigger exists in the project, the Stack change must pass the
approved infrastructure lifecycle: source change, offline validation, remote
plan through the Terraform MCP, review of the exact plan, explicit
authorization, apply, remote verification. This document does not authorize
that apply.

## Service wrapper layout

A normal service wrapper in the owning repository contains only:

```text
deploy/helm/<service>/
  Chart.yaml          # pins one exact platform chart version as a dependency
  Chart.lock          # committed dependency lock
  values.yaml         # base values within the profile schema
  values-dev.yaml     # minimal environment overlay
  values-prod.yaml    # minimal environment overlay
```

```yaml
# Chart.yaml
apiVersion: v2
name: <service>
type: application
version: 0.1.0
dependencies:
  - name: platform-service
    version: 1.2.3                      # exact approved platform chart version
    repository: oci://<location>-docker.pkg.dev/<project>/<helm-repository>
    alias: service
```

It contains no copied platform templates and no application source. Adopting
a new platform chart version is an explicit change to the pinned dependency
and committed `Chart.lock`, followed by the service's authoritative tests and
its dev-to-production lifecycle. Publication of a chart version alone changes
no running service.

`Chart.lock` can be generated only after the platform chart version has been
published; wrappers therefore follow publication, not the reverse.

## Migration of the transitional charts

The charts currently under `helm/` in this repository (`yourown-chat`, `mcp`,
`agent-platform`, `mattermost`, `matterbridge`) predate the policy. They remain
the deployed source until each is replaced, component by component:

1. publish the platform profile versions the component needs;
2. add the minimal wrapper and environment overlays in the owning repository
   listed in [REPOSITORIES.md](REPOSITORIES.md), pinning the profile and
   committing `Chart.lock`;
3. render both the transitional chart and the wrapper for every environment
   and compare the resulting workload, network, identity and secret objects;
   differences are either wrapper corrections or explicitly approved platform
   capabilities;
4. switch the generic Skaffold and Cloud Deploy rendering for that component
   to the wrapper through the approved delivery lifecycle (development
   verification, explicit production approval, production verification);
5. remove the transitional chart from this repository in a separate reviewed
   change after the wrapper has been promoted and verified.

Steps 1 and 4 are serialized operations: chart publication needs the applied
publication rail, and the rendering switch is a release. Each requires the
explicit authorization and release lock defined by the release policy and the
private release-coordination procedure. The order of components and the
profile selected for each are recorded in the private repository map.

## Verification

Local, offline, on a task branch:

```bash
for chart in helm/platform/*/; do helm dependency build "$chart" 2>/dev/null || true; helm lint --strict "$chart"; done
for test in helm/test/platform-*.test.sh; do bash "$test"; done
terraform fmt -check -recursive terraform/app-gcp/modules/chart-publish
```

Remote, after merge, through the approved MCP: the `platform-chart-publish`
build status and logs, the published chart versions and digests in Artifact
Registry, and the evidence objects. A check that did not run against the exact
revision being handed off is reported as not verified.
