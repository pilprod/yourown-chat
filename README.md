# yourown-chat-stack

Production-grade, cloud-agnostic-where-practical GCP platform, managed with
**HCP Terraform + Terraform Stacks** and validated in **GitLab CI**.

This repository currently implements the **first platform slice**, sized to a
**~$100/mo budget** (single zonal cluster, two isolated node pools):

| Capability | Implementation |
|------------|----------------|
| PostgreSQL database (Germany) | Cloud SQL for PostgreSQL, private IP, `europe-west3`, PITR + 7-day backups |
| Object storage ("S3") | Cloud Storage bucket, `EUROPE-WEST3` (+ S3-compatible HMAC creds for Mattermost) |
| Kubernetes | One **zonal** GKE Standard cluster, **two node pools** (prod `e2-standard-2` tainted + dev `e2-small`), private nodes |
| Container registry | Artifact Registry (Docker) — the supported replacement for GCR |
| CI build | Cloud Build (least-privilege SA) |
| CD to GKE | Cloud Deploy delivery pipeline + GKE target |
| Secrets | **Every** credential in **Secret Manager**, mounted via the GKE Secret Manager CSI add-on + Workload Identity |
| Apps | Prod Mattermost (operator CR) + dev Mattermost + matterbridge, pinned to their node pools |

> There is no "S3" on GCP — the equivalent is a **Cloud Storage (GCS) bucket**,
> which is what this stack provisions in the same German region.

---

## Architecture rationale & tradeoffs

The brief asks for a **production-grade** platform *and* the **cheapest** GKE,
under a **$100/mo ceiling**. Rather than three separate clusters (which multiply
the spend), the budget default is **one zonal cluster with two node pools**, so
prod is genuinely isolated from dev without paying for a second control plane.

| Line item | Config | ~$/mo |
|-----------|--------|-------|
| GKE control plane | 1 zonal cluster | $0 (free tier) |
| prod node pool | 1× `e2-standard-2` (tainted `dedicated=prod`) | ~$49 |
| dev + matterbridge pool | 1× `e2-small` | ~$12 |
| Cloud SQL (prod) | `db-f1-micro`, 20Gi SSD, PITR + 7-day backups | ~$12–15 |
| GCS (prod filestore) | Standard, small | ~$2 |
| dev PVCs (pg 5Gi + filestore 10Gi) | pd-standard | ~$0.6 |
| Buffer (egress/growth) | | ~$10–15 |
| **Total** | | **~$86–93** |

Every cost/HA knob is a typed variable with a production-safe path — HA Cloud SQL
or per-environment clusters are one deployment/variable away once the budget is
raised:

| Concern | Budget default | Harden (flip a variable) |
|---------|----------------|--------------------------|
| GKE control plane | Zonal (free) | `gke_regional = true` |
| Prod nodes | 1× `e2-standard-2`, on-demand | bump `max_count` / machine type |
| Cloud SQL | `db-f1-micro`, `ZONAL`, PITR on | `db-custom-*`, `REGIONAL` (HA) |
| Environments | prod + dev tiers on one cluster | add `stage`/`prod` deployments |
| Control-plane access | `master_authorized_networks` (CI CIDR) | keep restricted |

Non-negotiable production practices are kept **even at this budget**: private
nodes + Cloud NAT egress, Workload Identity, Shielded Nodes, private-IP Cloud SQL
over Private Service Access, uniform bucket access + public-access prevention,
dedicated least-privilege service accounts, **all secrets in Secret Manager**,
and encryption on by default (CMEK-ready).

**Node-pool isolation:** the prod pool carries a `dedicated=prod:NoSchedule`
taint + `tier=prod` label; prod workloads set a matching `nodeSelector` +
toleration. Dev/bridge workloads select `tier=dev` and never tolerate the prod
taint, so dev load can't contend with prod.

**GKE Standard vs Autopilot:** Standard is chosen because the target
architecture calls for explicit multiple node pools and node-level cost control
(machine type, disk, taints) that Autopilot abstracts away.

## Dependency graph

```mermaid
graph TD
  PS[project-services<br/>enable APIs] --> NET[network<br/>VPC/NAT/PSA]
  PS --> STO[storage<br/>GCS + HMAC creds]
  PS --> AR[artifact-registry]
  PS --> WI[workload-identity<br/>GSA per tenant]
  PS --> SEC[secrets<br/>Secret Manager]
  NET --> SQL[cloudsql<br/>private PostgreSQL + conn secret]
  NET --> GKE[gke<br/>1 cluster / 2 node pools]
  WI -->|accessors| SQL
  WI -->|accessors| STO
  WI -->|accessors| SEC
  GKE --> CD[clouddeploy<br/>pipeline + target]
  AR --> CD
  AR --> CB[cloudbuild<br/>build SA + IAM]
  CD --> CB
```

Ordering is expressed by components referencing each other's outputs — explicit
dependencies, no implicit ordering. Workload Identity SA emails flow into the
secret-owning components as least-privilege `secretAccessor` members.

## Repository layout

```
.terraform-version        # Terraform Core version pin (read by HCP Stacks + CI)
.terraform.lock.hcl       # provider lock (committed at the stack root; HCP reads it)
providers.tfcomponent.hcl # stack provider requirements + configuration
variables.tfcomponent.hcl # typed stack input variables
components.tfcomponent.hcl # component wiring (one block per platform building block)
outputs.tfcomponent.hcl   # stack outputs
deployments.tfdeploy.hcl  # one "platform" deployment (budget topology)
infra/
  modules/                # small, single-purpose, reusable modules
    project-services/     # API enablement (dependency root)
    network/              # VPC, subnet(+secondary ranges), Router, NAT, PSA
    gke/                  # zonal Standard cluster + node_pools map + WI + CSI
    cloudsql/             # private PostgreSQL + DB + user + password/conn secrets
    storage/              # GCS bucket (+ optional Mattermost S3 HMAC creds)
    artifact-registry/    # Docker repo
    cloudbuild/           # build identity + least-privilege IAM
    clouddeploy/          # delivery pipeline + GKE target + execution SA
    secrets/              # Secret Manager map (generate/provide + accessors)
    workload-identity/    # per-tenant GSA bound to a KSA (WI)
  environments/           # per-env docs (env == Stacks deployment)
platform/                 # GitOps manifests (separate from infra + app)
  namespaces.yaml
  mattermost/             # prod: SA + SecretProviderClass + secret-sync + CR
  matterbridge/           # SA + SecretProviderClass + Deployment (dev pool)
  dev/                    # SA/SPC + in-cluster Postgres + dev Mattermost
app/                      # sample workload + CI/CD manifests
  Dockerfile, index.html
  k8s/                    # deployment.yaml, service.yaml
  skaffold.yaml           # consumed by Cloud Deploy
  cloudbuild.yaml         # build -> push -> create release
.gitlab-ci.yml            # module fmt/validate + manifest lint
```

> Stack layout: the Terraform Stacks configuration lives at the **repository
> root**, using the `*.tfcomponent.hcl` (components, providers, variables,
> outputs) and `*.tfdeploy.hcl` (deployments) file suffixes that current
> Terraform Stacks requires. Root placement is deliberate: HCP Terraform reads
> the stack from the root of the connected repository, and it is what pulls the
> local `infra/modules/` into the stack source bundle (a nested stack dir would
> exclude them). A committed `.terraform.lock.hcl` pins provider versions and
> hashes for reproducible runs.

> Version pin: HCP Terraform Stacks selects the Terraform Core version from the
> repo-root **`.terraform-version`** file (currently `1.15.8`). The GitLab CI
> images are pinned to the same version so local, CI, and HCP runs agree.

> Separation of concerns: **infra** (Terraform) provisions cloud resources,
> **platform/** (GitOps) runs the chat workloads, and **app/** is a sample
> deployed by Cloud Deploy — stateful, platform, and stateless are kept apart.

## Deploying (HCP Terraform Stacks)

1. Create **one** GCP project with billing linked, or reuse an existing one.
   This slice does **not** create projects/org (that is a separate future
   foundation stack requiring org + billing permissions).
2. In `deployments.tfdeploy.hcl` (repo root), replace every `REPLACE-ME-*`
   value in the `platform` deployment (project ID, authorized networks).
3. Configure GCP auth in HCP Terraform — either:
   - **OIDC dynamic credentials (recommended, keyless):** set up Workload
     Identity Federation and uncomment/complete the `identity_token` block, or
   - **variable set / store:** provide `GOOGLE_CREDENTIALS` via an HCP variable
     set and wire it through `google_credentials`.
   No credentials are ever committed.
4. Create the Stack in HCP Terraform pointing at the repository **root**, then
   plan and apply the `platform` deployment.
5. Deploy the chat workloads from [`platform/`](platform/README.md): install the
   ingress-nginx controller + Mattermost operator, replace the `REPLACE-ME-*`
   markers (project ID, bucket, Workload Identity SA emails from
   `terraform output workload_identity_emails`), then apply the manifests.

## CI/CD flow

```
GitLab push ──► Cloud Build (build image ─► push to Artifact Registry)
                     └─► gcloud deploy releases create
                             └─► Cloud Deploy delivery pipeline ─► GKE target
```

- `app/cloudbuild.yaml` runs as the Terraform-provisioned Cloud Build SA
  (repo-scoped AR writer + `clouddeploy.releaser` + `actAs` the Cloud Deploy
  execution SA).
- Connecting Cloud Build to **GitLab** requires a Cloud Build 2nd-gen
  connection backed by a GitLab PAT in Secret Manager — a one-time manual/
  scripted step, intentionally left out of Terraform (keeps the secret out of
  code). See open questions.

## Security considerations

- Least-privilege, per-purpose service accounts (node, build, deploy, per-tenant
  Workload Identity); the default compute SA is never used.
- Private GKE nodes; egress only via Cloud NAT; Workload Identity for every pod
  that touches GCP.
- Cloud SQL private IP only (`ipv4_enabled = false`), `ENCRYPTED_ONLY` TLS.
- **All secrets in Secret Manager** — DB password + connection URI (cloudsql),
  GCS S3-compatible HMAC keys (storage), dev Postgres password + matterbridge
  config (secrets module). None are surfaced as plaintext outputs; pods read
  them via the GKE Secret Manager CSI add-on, gated by per-tenant `secretAccessor`
  IAM (a workload can read only its own secrets).
- Buckets: uniform bucket-level access + public access prevention enforced.
- **Flagged:** set `master_authorized_networks` to your CI/office CIDRs before
  real use (the deployment ships a `REPLACE-ME/32` placeholder).

## Future scalability

Modules are intentionally small so the rest of the platform vision (Vault,
Authentik, ingress-nginx, cert-manager, ExternalDNS, Prometheus/Grafana/Loki)
slots in as **new components** in the same Stack, and additional
regions/environments as **new deployments** — no root-module rewrites. Mattermost
and matterbridge already run as GitOps workloads in [`platform/`](platform/).
The network module is already hub-and-spoke-ready and provisions PSA for future
private managed services. Raising the budget promotes dev/stage to their own
clusters (uncomment the scale-out deployment) or Cloud SQL to `REGIONAL` HA.

## Decisions made autonomously — please review

These were resolved without you (you were unavailable) and are easy to change:

1. **Region:** `europe-west3` (Frankfurt) over `europe-west10` (Berlin) —
   cheaper and more mature. One-variable change.
2. **Topology:** one zonal cluster + two node pools (prod/dev tiers) instead of
   three clusters, to fit the ~$100/mo budget. Scale-out path is documented and
   stubbed in `deployments.tfdeploy.hcl`.
3. **Scope:** provisions into an **existing** `project_id`; org/project
   bootstrap deferred to a foundation stack.
4. **Cloud SQL:** `db-f1-micro` + PITR + 7-day backups, no HA (HA alone would
   consume most of the budget — raise the ceiling first if HA is required).
5. **Apps:** prod Mattermost via the operator CR (external Cloud SQL + GCS
   filestore); dev Mattermost + matterbridge as lightweight Deployments. Confirm
   the Mattermost operator version, ingress host, and matterbridge bridges.
6. **GitLab ↔ Cloud Build** connection details (host, PAT) still needed to
   create triggers in Terraform.
7. **Auth model:** OIDC vs variable set — confirm which HCP mechanism to wire.
