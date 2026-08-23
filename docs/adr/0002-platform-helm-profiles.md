# ADR 0002: Platform Helm profiles, typed values contract and chart publication

- Status: Proposed (implementation prepared; awaiting project-owner acceptance)
- Date: 2026-08-22
- Decision owner: Project owner

## Context

The public Helm platform policy, now retained in the disconnected archive at
`pilprod/yourown-chat-rules/public/helm-policy.md`, was accepted on
2026-08-22. It specified reusable platform charts with strict typed values
contracts, immutable versioned OCI publication, and minimal service wrappers in
the owning repositories. The repository currently contains five
service-specific charts under `helm/` (`yourown-chat`, `mcp`, `agent-platform`,
`mattermost`, `matterbridge`) that render Deployments, Services, NetworkPolicies,
SecretProviderClasses and Ingresses independently, with service values and
environment overlays stored in the public platform repository, and no chart is
published as an artifact. Service repositories contain no release wrappers.

Parallel agent work in the same repository is coordinated through the private
registry (`pilprod/yourown-chat-rules` Issues #5, #6 and #7).

## Decision

1. **Four platform profiles** are implemented as Helm charts under
   `helm/platform/`: `platform-service`, `platform-worker`, `platform-job`,
   `platform-stateful`. Shared rendering (labels, security context, probes,
   secret mounts, deny-by-default network policy) is maintained once under
   `helm/platform/_common` and synchronized into every profile, so each
   published profile chart is self-contained; a sibling `file://` library
   dependency remains an accepted alternative. Each profile ships a strict
   `values.schema.json` (`additionalProperties: false`), deterministic render
   tests and negative policy tests under `helm/test/platform-*.test.sh`.
2. **Typed capabilities only.** Image identity is an immutable digest supplied
   as a release parameter; Workload Identity, secret references (CSI Secret
   Manager, `provider: gke`), network allow rules, HTTP ingress, the narrow
   multi-protocol layer-four transport capability, bounded resources, probes,
   disruption budgets and the `enabled`/`paused` controls are schema-defined
   values. Raw Kubernetes objects, arbitrary annotations, host networking,
   `NodePort`, privileged mode, arbitrary service accounts, cluster RBAC and
   plaintext secret environment variables have no representation.
3. **Publication rail.** A dedicated `chart-publish` identity and a
   canonical-branch Cloud Build trigger (`platform-chart-publish`, module
   `terraform/app-gcp/modules/chart-publish`, component `chart_publish` of the
   `app-gcp` Stack) lint and test every platform chart and publish each
   application chart version exactly once into the dedicated immutable-tag
   Helm chart repository owned by `platform-gcp`
   (`oci://<location>-docker.pkg.dev/<project>/<helm-repository>/<chart>`);
   the rail stays unmaterialized until that repository is published to
   `app-gcp`.
   Immutability is decided against the registry: an already published
   version is pulled and compared with the packaged source; identical content
   is recorded as already published (retry-safe), different content fails the
   build. Publication requires the platform test scripts to be present and
   passing. Evidence (source revision, build ID, version, publication state,
   OCI digest, package SHA-256, Helm version, test outcome) is recorded per
   version in a dedicated durable evidence bucket.
4. **Wrappers follow publication.** Each owning service repository adds a
   minimal wrapper (`Chart.yaml` pinning one exact profile version,
   `Chart.lock`, base values, minimal environment overlays). Generic Skaffold
   and Cloud Deploy integration renders from the wrapper. Transitional charts
   in this repository are removed component by component only after the
   wrapper has been promoted and verified through the delivery lifecycle.
5. **Private assignments stay private.** Component-to-profile selection,
   direct-transport exceptions and tunnel mappings are recorded in the private
   repository map, not in public charts or documentation.

## Consequences

- One security, identity, secret, network and observability implementation is
  maintained in the platform repository; service repositories stop owning
  Kubernetes implementation detail.
- Service teams receive a reviewable contract (`helm show values` of a pinned
  version) and adopt changes through an explicit dependency bump, never through
  silent chart mutation.
- Publication becomes an auditable, immutable step with recorded evidence.
  The first publication requires the `app-gcp` Stack change to pass the
  approved infrastructure lifecycle (MCP plan, review, explicit authorization,
  apply, verification).
- A migration period exists in which transitional charts and wrappers coexist.
  The rendering switch for each component is a release and follows the release
  policy and the private release-coordination procedure.
- Existing repository-specific instructions in service repositories that
  locate Helm exclusively in the platform repository must be reconciled with
  the private ownership map before wrappers are added; that reconciliation is
  an owner decision.
- The transitional `helm/mattermost/rtcd/source.lock` still references the
  legacy RTCD repository; the RTCD adapter work replaces it under the
  stateful profile in a later phase.

## References

- `pilprod/yourown-chat-rules/public/helm-policy.md`,
  `public/infrastructure-policy.md`, `public/release-policy.md` and
  `public/multi-agent-workflow.md` in the same disconnected archive
- `docs/HELM_PLATFORM.md`
- `pilprod/yourown-chat-rules` Issues #5, #6, #7
