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
| `yourown-chat-server` | `yourown-chat-auth-api`, `yourown-chat-identity-api`, `yourown-chat-identity-admin`, `yourown-chat-identity-migrate` and `yourown-chat-control-api`, followed by the independent approval-gated `yourown-chat` release |
| `yourown-chat-agents` | `yourown-chat-workflow-worker` and `yourown-chat-activity-worker` |

The server application is released as soon as its five images pass the gate;
it does not wait for agent compute or Temporal. Server and agents also use the
same compatibility tag for the agent release. Each repository builds only its
own images. The first completed source build waits successfully if the matching
control and worker images do not exist yet; whichever build first observes the
compatible set creates the agent Cloud Deploy release. Deterministic release
names make simultaneous attempts harmless.

The tag in each repository must point to the current reviewed remote `main`.
Before pushing it, the release operator compares local `HEAD` and `origin/main`
and verifies the repository is clean. The private Gen2 connector does not expose
its GitHub credential to build containers, so the build must not add a second
network fetch or store a separate GitHub token merely to repeat this check.
Agents are intentionally not a Git submodule of `yourown-chat`: matching
immutable source tags coordinate independently built image digests without
copying application code into the platform repository.

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
- server source tags build, scan and may release identity services, while
  `control-api` remains absent from the rendered chart;
- agent source tags may build and scan immutable worker images;
- neither source tags nor platform tags can create an agent workload release.

This keeps infrastructure preparation independent from the prerequisite MCP
rollout.

## Required first-launch order

1. In the Cloud Build GitHub connection, authorize `yourown-chat-mcp`,
   `yourown-chat-server` and `yourown-chat-agents`.
2. Apply `platform-gcp` with `temporal_enabled=false`, then apply the linked
   `app-gcp` plan. This creates the retained identity logical database, the
   `server-edge`, `server-identity` and `server-control` trust-zone namespaces
   and the independent `yourown-chat` delivery
   pipeline. Verify repository links and the `*-ci` / `*-image` triggers exist.
3. Tag `yourown-chat-server`, approve `yourown-chat-pilot`, and verify identity
   registration, login and Mattermost linking before enabling agent compute.
4. Tag `yourown-chat-mcp` with the next immutable release tag. Let Cloud Deploy
   pass dev verification, approve prod and complete prod verification.
5. Change only `temporal_enabled` to `true` in `platform-gcp`, review and apply
   that plan. Terraform extends the existing Cloud SQL/storage owners with the
   two logical databases, Secret Manager password and results bucket, then
   installs the isolated pinned official Temporal chart.
6. Review and apply the automatically linked `app-gcp` plan so delivery receives
   the platform readiness and result-bucket outputs. Verify the Temporal
   frontend and schema jobs before deploying custom
   workloads.
7. Verify both repositories are at their clean, reviewed remote `main` heads,
   then create the same new immutable release tag in `yourown-chat-server` and
   `yourown-chat-agents`. Never tag the old feature-branch SHA after a squash
   merge. The coordinated tag build creates one paused agent release by
   default.
8. Approve the paused baseline, then use `helm/agent-pilot.sh cloud-start` and
   approve the start release for the dry-run test.
9. After testing, run `helm/agent-pilot.sh cloud-pause` and approve it. Use
   `cloud-pause-now` only for a reversible emergency scale-to-zero, then
   reconcile with the normal pause release.

For the first coordinated release of repositories with no existing release
tag, use the same initial version (normally `0.1.0`) after their pull requests
are present on remote `main`. The safe operator sequence for each repository is:

```bash
git fetch origin main --tags
git switch main
git pull --ff-only origin main
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git tag -a 0.1.0 -m "Release 0.1.0"
git push origin refs/tags/0.1.0
```

Run it in `yourown-chat-server` and `yourown-chat-agents`, changing the version
in both places together for later releases. Do not reuse the existing MCP tag
as a Git dependency: MCP has an independent lifecycle even when its numeric
version happens to match.

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

Mattermost server source and RTCD are maintained upstream forks and keep their
`vMAJOR.MINOR.PATCH-patched` source lifecycle. The
`yourown-chat-mattermost` assembly uses stable `MAJOR.MINOR.PATCH` tags and
dev-only `MAJOR.MINOR.PATCH-suffix` prereleases. First-party `yourown-chat`,
MCP, server and agents repositories also use plain `MAJOR.MINOR.PATCH`.

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
