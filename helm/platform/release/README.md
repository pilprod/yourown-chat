# Platform release integration

This directory is the generic, platform-owned Skaffold and Cloud Deploy
integration for services delivered through the platform workload profiles. It
turns a service repository's release manifest and release wrappers into one
Cloud Deploy release source, validates everything against the platform
contract before a release is created, and records release evidence.

Service repositories own only:

- `helm/release.yaml` — the release manifest (schema: [`manifest/values.schema.json`](manifest/values.schema.json));
- one wrapper chart per release under `helm/<wrapper>/`: `Chart.yaml`
  (exact pinned platform profile dependencies with aliases), `Chart.lock`,
  `values.yaml`, optional `values-<overlay>.yaml` overlays, `README.md`.

They contain no Skaffold configuration, no Cloud Build configuration, no
templates and no release parameters.

## Release manifest

```yaml
apiVersion: platform.yourown.chat/v1
kind: ReleaseManifest
wrappers:
  - name: identity            # Helm release name inside the Cloud Deploy release
    path: helm/identity       # wrapper chart directory in the service repository
    namespace: identity       # platform-provisioned namespace
    workloads:                # one entry per dependency alias of the wrapper
      identity-api:
        image: yourown-chat-identity-api          # image name built by this repository
      identity-migrate:
        image: yourown-chat-identity-migrate
        identity: identity-migrate                # Workload Identity key (default: alias)
```

The manifest workloads must be exactly the aliases pinned in the wrapper's
`Chart.yaml`; aliases are unique across the whole release. Optional workloads
are switched with chart `tags`; `condition` and `import-values` are rejected
because they would inject keys into the profile schema.

### Profiles

A wrapper may list the Cloud Deploy profiles it belongs to
(`profiles: [mcp-dev]`); without the list it is rendered in every requested
profile. Every requested profile must select at least one wrapper.

### Verification

```yaml
    verify:
      http:
        - name: identity-api-ready
          url: http://identity-api.identity.svc.cluster.local:8081/readyz
          retries: 30        # optional, default 30
          delaySeconds: 5    # optional, default 5
```

Each wrapper may declare typed in-cluster HTTP checks; a wrapper that pins
`platform-service` or `platform-stateful` must declare at least one. The
assembler turns them into a Cloud Deploy `verify` entry per wrapper and profile
(a `curl` container with retries, running as a Job in the wrapper namespace
from the generated `verify/<wrapper>.yaml` manifest with the `app: verify`
label). The service allows that traffic with a typed ingress rule
(`from: { sameNamespace: true, podLabels: { app: verify } }`). Workers and jobs
are verified by rollout status and completion.

## `assemble.sh`

```text
assemble.sh --repo <service checkout> --out <release source> --evidence <dir>
            --chart-registry oci://<region>-docker.pkg.dev/<project>/<repo>
            --profile <cloud-deploy-profile>=<overlay> ...
            --image <image-name>=<repository@sha256:digest> ...
            --identity <key>=<service-account-email> ...
            --secret-project <project> [--cluster-dns-ip <ip>]
            --source-revision <sha> --platform-revision <sha>
```

For every wrapper it:

1. validates the manifest with the manifest chart schema;
2. rejects wrappers that contain templates, CRDs, a schema, unexpected files,
   non-profile dependencies, version ranges, foreign registries, or a missing
   `Chart.lock`;
3. copies the wrapper and runs `helm dependency build` against the platform
   chart registry (`file://` dependencies are accepted only with
   `--allow-file-dependencies`, used by the tests);
4. renders each requested Cloud Deploy profile with `values.yaml`, the matching
   `values-<overlay>.yaml` when it exists, and the typed release parameters,
   so every profile schema is enforced before a release exists;
5. runs [`policy-check.sh`](policy-check.sh) on each render (platform
   invariants and profile-label/kind consistency);
6. writes the generic `skaffold.yaml` with the verification entries, the
   per-wrapper verification Job manifests, the `deploy-parameters` line, and
   `release-evidence.json` (platform chart artifacts and digests, `Chart.lock`
   digest, image references, overlay digests, typed release parameters and the
   resolved-configuration digest per profile).

Typed release parameters are the only values injected at release time:
`<alias>.image.digest`, `<alias>.identity.googleServiceAccount`,
`<alias>.secrets.project` and `<alias>.network.clusterDNSIP` (the Secret
Manager project and the cluster DNS address are required). Cloud Deploy passes
them to Helm as `--set` arguments; keys stay within the 63-character limit,
values within 512 characters, and one release carries at most 50.

### Lifecycle actions

- `--cleanup-action NAME=PROFILE` generates the Cloud Deploy custom action
  `NAME` that scales every Deployment and StatefulSet rendered by `PROFILE` to
  zero (disposable development stage cleanup; the Terraform pipeline stage
  references the action name, and the cleanup identity's RBAC must cover the
  wrapper workload names).
- `--actions FILE` appends a platform-owned `customActions:` document (for
  example [`actions/mcp-capability-sync.yaml`](actions/mcp-capability-sync.yaml))
  verbatim; the release evidence records the file digest.

## Cloud Build wiring

`terraform/app-gcp/modules/deploy-release` runs the assembler in the
`wrapper-release` step of the server, agent and MCP source triggers when
`wrapper_releases_enabled` is true, installs the Helm release pinned in
[`tooling.env`](tooling.env), authenticates to the chart registry with the
build identity, creates the Cloud Deploy release from the assembled source and
uploads the evidence next to the image evidence. The legacy chart release path
is skipped while the switch is on. The `platform-charts` trigger
(`chart_publication_enabled`) tests and publishes missing `helm/platform`
chart versions on platform release tags; published versions are never rebuilt.

## Tests

```bash
bash helm/test/platform-release.test.sh
```

exercises the assembler against `helm/test/fixtures/platform/service-repo`,
compares the generated `skaffold.yaml` with
`helm/test/golden/platform/release-skaffold.yaml`, checks determinism and the
evidence contents, and verifies the contract rejections.
