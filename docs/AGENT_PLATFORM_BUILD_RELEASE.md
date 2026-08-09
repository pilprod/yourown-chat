# Agent platform build, release and Temporal launch

This is the operational source of truth for the custom server, agent workers
and the Terraform-owned Temporal platform.

## One regional GitHub connection

Authorize these repositories in the existing `pilprod-github` Cloud Build
GitHub App connection in `europe-west3`:

- `pilprod/yourown-chat`;
- `pilprod/yourown-chat-server`;
- `pilprod/yourown-chat-agents`;
- `pilprod/yourown-chat-mcp`;
- `pilprod/yourown-chat-mattermost`;
- `pilprod/yourown-chat-rtcd`.

OAuth authorization is the only manual bootstrap. Terraform owns repository
resources, triggers, build identities and IAM after the repositories are
visible to the connection. Do not create parallel console-owned triggers.

## Tag-driven source releases

`main` triggers CI only. It runs format/lock verification, `go vet`, race tests,
Temporal workflow checks where applicable, `govulncheck`, image build,
SBOM/provenance generation and Google On-Demand Scanning. It publishes only a
commit-addressed image and never deploys.

An immutable tag matching `MAJOR.MINOR.PATCH` (for example `0.1.0`) repeats the complete
gate and is the only source event allowed to create a release:

| Source | Trigger outputs |
|---|---|
| `yourown-chat-mcp` | `mcp-google-cloud` and `mcp-terraform-stacks`, then MCP dev -> verify -> approval -> prod |
| `yourown-chat-server` | `yourown-chat-control-api` |
| `yourown-chat-agents` | `yourown-chat-workflow-worker` and `yourown-chat-activity-worker` |

Server and agents use the same release tag. Each repository builds only its own
images. The first completed source build waits successfully if the matching
images do not exist yet; whichever build first observes all three immutable
digests creates a single coordinated Cloud Deploy release. A deterministic
release name makes a simultaneous second attempt harmless.

This rule prevents a newly tagged server from being deployed with an unrelated
worker version while preserving independent source repositories and build
identities.

High or Critical image findings block publication. Evidence, coverage, digest,
scan ID and vulnerability JSON are retained under the private release-source
bucket. Kubernetes receives only digest-qualified image references.

## Temporal launch gate

`agent_platform_enabled=true` in `app-gcp` prepares namespaces, delivery
pipelines, source repository links and all four server/agent Cloud Build
triggers. `temporal_enabled=false` belongs to `platform-gcp`; it is a separate
hard launch gate and the committed default. `app-gcp` consumes this value only
through the published platform output. While it is false:

- Terraform does not create Temporal databases, password, bucket, namespace or
  Helm release;
- source tags may build and scan immutable workload images;
- neither source tags nor platform tags can create an agent workload release.

This keeps infrastructure preparation independent from the prerequisite MCP
rollout.

## Required first-launch order

1. In the Cloud Build GitHub connection, authorize `yourown-chat-mcp`,
   `yourown-chat-server` and `yourown-chat-agents`.
2. Apply `platform-gcp` with `temporal_enabled=false`, then apply the linked
   `app-gcp` plan. Verify repository links and the `*-ci` / `*-image` triggers
   exist.
3. Tag `yourown-chat-mcp` with the next immutable release tag. Let Cloud Deploy
   pass dev verification, approve prod and complete prod verification.
4. Change only `temporal_enabled` to `true` in `platform-gcp`, review and apply
   that plan. Terraform extends the existing Cloud SQL/storage owners with the
   two logical databases, Secret Manager password and results bucket, then
   installs the isolated pinned official Temporal chart.
5. Review and apply the automatically linked `app-gcp` plan so delivery receives
   the platform readiness and result-bucket outputs. Verify the Temporal
   frontend and schema jobs before deploying custom
   workloads.
6. Create the same new immutable release tag in `yourown-chat-server` and
   `yourown-chat-agents`. The coordinated tag build creates one paused agent
   release by default.
7. Approve the paused baseline, then use `helm/agent-pilot.sh cloud-start` and
   approve the start release for the dry-run test.
8. After testing, run `helm/agent-pilot.sh cloud-pause` and approve it. Use
   `cloud-pause-now` only for a reversible emergency scale-to-zero, then
   reconcile with the normal pause release.

Do not flip `platform-gcp.temporal_enabled` before the first `app-gcp` trigger
apply and the prerequisite MCP production verification. Do not reuse or move a
release tag.

## Expected triggers

After the first preparation apply, the regional Cloud Build trigger list must
include:

```text
yourown-chat-mcp-ci
yourown-chat-mcp-image
yourown-chat-server-ci
yourown-chat-server-image
yourown-chat-agents-ci
yourown-chat-agents-image
```

Mattermost and RTCD are maintained upstream forks and keep independent
`vMAJOR.MINOR.PATCH-patched` tag-driven pipelines. First-party `yourown-chat`,
MCP, server and agents repositories use plain `MAJOR.MINOR.PATCH`.

## Verification commands

Before applying:

```bash
terraform stacks -chdir=terraform/platform-gcp validate
terraform -chdir=terraform/app-gcp/modules/deploy-release validate
terraform stacks -chdir=terraform/app-gcp validate
bash helm/test/agent-platform.test.sh
bash helm/test/agent-routing.test.sh
```

After enabling Temporal:

```bash
kubectl -n temporal get pods,jobs,svc
kubectl -n temporal get networkpolicy,resourcequota,limitrange
helm/agent-pilot.sh cloud-status
```

The first workflow test must remain a no-side-effect dry run with a real
approve/reject round trip and a persisted report.
