# Deploying workloads

Terraform owns the delivery rails and long-lived dependencies. Cloud Deploy
owns only application rollouts. This separation prevents an unchanged database
or unrelated component from being reapplied during every release.

## Release topology

```mermaid
flowchart TD
  MT["pilprod/mattermost tag<br/>v*.*-patched"] --> BUILD["Build and push image"]
  BUILD --> MMTEST["mattermost / dev<br/>migration + smoke"]
  MMTEST --> MMAPPROVE["approval"]
  MMAPPROVE --> MMCLEAN["predeploy: scale dev Mattermost to 0"]
  MMCLEAN --> MMPROD["mattermost / prod<br/>rolling rollout"]

  PT["yourown-chat tag<br/>MAJOR.MINOR.PATCH"] --> DIFF["diff from previous semver tag"]
  DIFF -->|"Mattermost paths"| MMTEST
  DIFF -->|"MCP paths"| MCPDEV["mcp / dev namespace<br/>readiness-gated rollout"]
  MCPDEV --> MCPAPPROVE["approval"]
  MCPAPPROVE --> MCPCLEAN["predeploy: scale dev MCP to 0"]
  MCPCLEAN --> MCPPROD["mcp / prod<br/>rollout + verify"]

  PG["Terraform Helm release<br/>dev-postgres"] --> MMTEST
```

There are two Cloud Deploy pipelines:

| Pipeline | Automatic stage | Review gate | After approval |
|---|---|---|---|
| `mattermost` | `mattermost-dev`; exercises migrations against persistent `dev-postgres` | verified dev stays running for reviewer checks | predeploy scales dev to zero, then the operator performs a rolling rollout |
| `mcp` | `mcp-dev`; creates readiness-gated `dev-mcp-*` deployments in the shared `dev` namespace | ready dev stays running for reviewer checks | predeploy scales dev to zero, then MCP prod deploys and executes read-only credential/API verification |

The Mattermost reviewer opens `https://dev.yourown.chat`. Cloudflare Access
admits only the configured reviewer emails, then the outbound-only Tunnel
routes the request to `dev-mattermost.dev.svc.cluster.local:8065`. There is no
public dev LoadBalancer or origin address. The hostname remains available from
successful verification until the reviewer approves production; that approval
starts the cleanup predeploy action.

Cleanup does not run as a Kubernetes Job. Cloud Deploy starts a Skaffold
custom-action container with no `executionMode.kubernetesCluster`, so it runs
in the Cloud Build execution environment under a dedicated
`cleanup-mattermost` or `cleanup-mcp` Google service account. Each identity can
read cluster metadata and is bound inside Kubernetes only to `get`, `patch`,
and `update` its exact disposable Deployment names. There is no cleanup
ServiceAccount, API-egress NetworkPolicy, or idle cleanup pod in GKE.

`dev-postgres` consists of Terraform-managed Kubernetes resources. Its PVC
survives application releases and provides a continuous migration history. The
current development database may be imported or replaced during the first
Terraform apply; it contains no important data.

## What starts a release

### A patched Mattermost source tag

Pushing `v*.*-patched` in `pilprod/mattermost` starts the image build. Only
after the image is successfully pushed does that build clone `yourown-chat`
`main` and create a release in the `mattermost` pipeline. Both stages receive
the same immutable image digest. The source tag remains in Chart metadata and
release annotations for readability, but is never used as the Kubernetes image
identity.

```bash
git tag v9.11.3-patched
git push origin v9.11.3-patched
```

This path needs no second tag in `yourown-chat`.
Its Cloud Deploy release ID is derived from the image version and includes the
short release-source commit plus the short Cloud Build ID when the production
rollout name remains within 63 characters:
`mattermost-11-9-0-img-a1b2c3d4-12345678`. If it does not fit, only the
optional build suffix is dropped; the source commit is retained.

### A unified platform tag

Pushing a `MAJOR.MINOR.PATCH` tag in this repository starts one router. It
compares the tagged commit with the previous semver platform tag:

- `helm/mattermost/` or `helm/matterbridge/` creates a
  `mattermost` release;
- `helm/mcp/` or `docker/` creates an `mcp` release when
  `mcp_servers_enabled=true`;
- `helm/skaffold-mattermost.yaml` routes only to `mattermost`;
- `helm/skaffold-mcp.yaml` routes only to `mcp`;
- unrelated changes create no Cloud Deploy release.

For a routed Mattermost release, the trigger resolves the newest
`v*-patched` tag in Artifact Registry, freezes its current digest, and passes
that immutable digest to both stages. A later platform release therefore
cannot accidentally restore the static chart default or skip a rollout because
a mutable tag string stayed unchanged.

```bash
git tag 1.2.3
git push origin 1.2.3
```

Component tags are intentionally not used. A platform version identifies one
reviewed repository state while the router avoids rolling unchanged workloads.

Platform tags follow an immutable-after-trigger policy:

- if a remote tag has started any Cloud Build release process, keep it forever,
  even when the build fails before Cloud Deploy creates a release;
- fix the problem in a new commit and publish the next semver tag;
- a tag may be deleted and recreated only when no Cloud Build was ever started
  for it and no Cloud Deploy release was created from it;
- never force-push an already triggered tag.

This keeps build, rollout, and audit records tied to one exact commit. Before
recreating an untriggered tag, verify in Cloud Build that no build exists for
the tag and in Cloud Deploy that no release carries that version.

## Mattermost guarantees

The dev stage deploys one Mattermost instance and waits for
`/api/v4/system/ping`. Application startup therefore has to complete any
database migrations before verification succeeds. Dev stays running for
review; after production approval, the prod rollout's predeploy action scales
dev Mattermost to zero, leaving PostgreSQL running.

Production has one replica and must not delete the old pod first. The
Mattermost operator's rolling behavior starts the replacement and waits for it
to become Ready before retiring the old instance. Do not change the production
strategy to `Recreate`; confirm the generated rollout before approving a
version that changes the operator or CR schema.

Agents operate Cloud Build and Cloud Deploy through the production Google
Cloud MCP, not through the Cloud SDK:

1. inspect the tag build with `google_cloud_build_inspect_build`;
2. inspect the frozen release and successful dev rollout/job runs;
3. call `google_cloud_deploy_plan_promote`, then pass its exact plan ID to
   `google_cloud_deploy_promote`;
4. inspect the production rollout etag and dev verification state;
5. call `google_cloud_deploy_approve_rollout`.

Rollback stays inside Cloud Deploy. Call
`google_cloud_deploy_plan_rollback` with a unique rollout ID and optionally an
exact previous release, review the validated configuration, then call
`google_cloud_deploy_rollback` with its exact plan ID. Cloud Deploy creates a
new auditable rollout from the previous frozen release and preserves rollout
history, deploy parameters, policy checks, and notifications. Do not use
`helm rollback`: native GKE targets have no installed Helm release state.

## MCP verification

The dev stage deploys all three prefixed instances into the shared `dev`
namespace. Cloud Deploy waits for their Kubernetes rollout; startup, readiness,
and liveness probes check the health endpoints. There is intentionally no dev
credential smoke: a process-level check with placeholder credentials would
give false confidence.

The ready dev deployments remain available for review. Production approval
runs their external cleanup hook as the prod predeploy step. The production
stage then deploys into the isolated MCP namespaces and performs real,
read-only upstream API calls through Terraform, Google Cloud, and WhatsApp
Business MCP. Official Gmail, Calendar, and Drive MCP connections are
vendor-hosted and are verified by each Mattermost user after OAuth consent
rather than by the GKE delivery pipeline.

Use the same MCP plan/promote, inspect/approve, and plan/rollback flows with
pipeline `mcp` and targets `mcp-dev` / `mcp-prod`.

## Manual release fallback

`helm/cloudbuild.yaml` creates one release. Choose the component explicitly:

```bash
gcloud builds submit \
  --config=helm/cloudbuild.yaml \
  --substitutions=_PIPELINE=mattermost .

gcloud builds submit \
  --config=helm/cloudbuild.yaml \
  --substitutions=_PIPELINE=mcp .
```

Direct Kubernetes application is only a debugging fallback because it bypasses
Cloud Deploy parameters, verification, cleanup, approval, and release history.

## Helm rendering and component retirement

The entries under `manifests.helm.releases` are render units, not Helm releases
installed in the cluster. Cloud Deploy calls `skaffold render`, freezes the
resulting Kubernetes manifests into the release, and applies them with
`kubectl`. Consequently:

- `helm list` does not show Mattermost or the MCP servers;
- `helm uninstall` cannot remove them;
- manually deleting a rendered workload is drift and the next Cloud Deploy
  rollout recreates it.

This is intentional. Native GKE targets in Cloud Deploy support Helm as a
renderer but use `kubectl` for deployment. Getting Helm release state would
require replacing both GKE targets with a custom target implementation that
runs `helm upgrade --install`. That would also require custom rollback,
cluster access and verification handling, so it is not justified merely to
support occasional component removal.

Retirement therefore uses the existing pipelines:

1. remove or disable the component in its chart/Skaffold profile;
2. add an explicit, idempotent cleanup action for the exact namespaced
   resources formerly owned by that component;
3. cut a normal platform tag and let routing select `mattermost` or `mcp`;
4. verify the disposable dev stage, approve production, then let the cleanup
   and desired manifests run in the audited rollout;
5. remove the one-release cleanup action after production no longer contains
   the retired component.

For an MCP server, keep its namespace, Secret Manager values and any PVC until
the retirement rollout has succeeded; deleting those is a separate Terraform
change. For Mattermost, delete only the Mattermost custom resource and its
application ServiceAccount. Cloud SQL, object storage, TLS and Terraform-owned
Secrets are long-lived dependencies and must never be part of application
retirement.

An emergency manual deletion remains possible, but it is not a release:

```bash
# Example only: stops one MCP workload while preserving its PVC and secrets.
kubectl --namespace mcp-google-cloud delete \
  deployment/mcp-google-cloud service/mcp-google-cloud

# Stops Mattermost through its operator without deleting external data.
kubectl --namespace mattermost delete \
  mattermost.installation.mattermost.com/mattermost
```

Record an emergency deletion and follow it with a versioned retirement change,
otherwise the next rollout restores the component.

## One-time apply and migration

Apply `platform-gcp` first, then `cloudflare` and `app-gcp`. Apply the
independent `agent-registry-gcp` stack after `platform-gcp` has enabled
`agentregistry.googleapis.com`. The app stack:

- creates namespaces and Secrets;
- owns the persistent `dev-postgres` Service and StatefulSet directly;
- creates the `mattermost` and `mcp` pipelines, their least-privilege execution
  identities, and dedicated external predeploy cleanup identities;
- creates the unified platform-tag trigger and Mattermost image trigger.

The platform now has one shared `general` pool using `e2-standard-2`
(`min=1`, `max=3`).
Production MCP uses the `production` PriorityClass, operator-generated
Mattermost and platform pods inherit `platform-default`, and all disposable dev
workloads explicitly use `development` (negative priority). The `dev` namespace
also has a ResourceQuota and LimitRange. Cluster Autoscaler can therefore add a
temporary node for a rollout and remove it again without keeping a mostly idle
dev VM.

The old database objects were previously applied by Cloud Deploy and are not
in Terraform state. Before the first apply of this change, remove only their
controllers. The generated PVC normally remains; deleting it too is acceptable
here because the current dev database contains no important data:

```bash
kubectl -n dev delete statefulset dev-postgres
kubectl -n dev delete service dev-postgres
# Optional clean start:
kubectl -n dev delete pvc data-dev-postgres-0
```

Do this before applying `platform-gcp`, because that apply removes the old dev
node pool and automatically queues the linked app stack. Then apply
`platform-gcp`; the following `app-gcp` run recreates PostgreSQL on the shared
pool and owns it from then on.

Before the first release, verify:

```bash
kubectl -n dev get statefulset,pod,pvc -l app=dev-postgres
gcloud deploy delivery-pipelines list --region=europe-west3
```

See [BUILD.md](BUILD.md) for image CI and [MCP.md](MCP.md) for credentials,
networking, and manual MCP diagnostics.
