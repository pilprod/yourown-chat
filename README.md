# YourOwn.Chat

Production-grade, cloud-agnostic-where-practical GCP platform, managed with
**HCP Terraform + Terraform Stacks**.

This repository implements the **first platform slice** as **one Terraform
Stack** (working directory `terraform/`) in a single GCP project. GCP, the
container CI and the Cloudflare edge are separate **components** of that one
stack, provisioned by a single **deployment** (`prod-eu`):

- **GCP platform** — a **single zonal GKE cluster with two node pools**, managed
  Cloud SQL, object storage and the Cloudflare-fronted public ingress. **prod and
  dev share this one cluster**: prod runs on a dedicated, tainted node pool;
  **dev is an isolated tenant namespace** (RBAC + default-deny NetworkPolicies)
  scheduled onto its own node pool.
- **Container CI** — one **unified** Artifact Registry repository (`docker`) plus
  the Mattermost image build (Cloud Build 2nd-gen), promoting a single image
  across environments by git tag.
- **Cloudflare edge** — the public edge for `yourown.chat`: the proxied apex A
  record wired **live** to the platform ingress IP, plus zone TLS/security
  settings, DNSSEC, WAF rules and origin TLS. It carries the only non-GCP secret
  (a zone-scoped Cloudflare API token), which stays isolated from the keyless GCP
  components.

> **One stack, not three.** These used to be three separate stacks
> (`platform`, `build`, `cloudflare`) with manual hand-offs between them.
> Consolidating them into one deployment removes every cross-stack step: the
> ingress IP is wired live into the Cloudflare record, and the Cloudflare Origin
> CA cert/key flow straight into the platform origin-TLS secrets. One HCP Stack,
> zero hand-offs.

| Capability | Implementation |
|------------|----------------|
| PostgreSQL database (Germany) | Cloud SQL for PostgreSQL, private IP, `europe-west3`, PITR + 7-day backups (prod) |
| Object storage ("S3") | Cloud Storage bucket, `EUROPE-WEST3` (+ S3-compatible HMAC creds for Mattermost) |
| Kubernetes | **One** zonal GKE Standard cluster, private nodes, **two node pools**: prod `e2-standard-2` (on-demand, tainted) + dev `e2-small` (on-demand, untainted) |
| Container registry | **One unified** Artifact Registry (Docker) repo `docker`, an `artifact_registry` component |
| CI build | Cloud Build (2nd-gen GitHub trigger, dedicated least-privilege SA) builds the Mattermost image |
| CD to GKE | Cloud Deploy **dev→prod** pipeline delivers the `helm/` workloads across two GKE targets on the one cluster — dev renders the dev tenant + matterbridge with a post-deploy `verify`, prod renders the operator-managed Mattermost gated by approval |
| Secrets | **Every** credential in **Secret Manager**, mounted via the GKE Secret Manager CSI add-on + Workload Identity |
| Encryption at rest | One shared **Cloud KMS HSM** key (CMEK, FIPS 140-2 Level 3, 90-day rotation) encrypts Cloud SQL, GCS and Secret Manager — customer-controlled key lifecycle over Google's default AES-256 (the public Artifact Registry is deliberately not CMEK-encrypted) |
| Apps | prod Mattermost (operator CR + managed Cloud SQL) and dev Mattermost + matterbridge + in-cluster Postgres, all on the one cluster |

> There is no "S3" on GCP — the equivalent is a **Cloud Storage (GCS) bucket**,
> which is what this stack provisions in the same German region.

---

## Architecture rationale & tradeoffs

The brief asks for a **production-grade** platform *and* the **cheapest** GKE,
under a ~**$100/mo** ceiling. The topology is therefore **one zonal cluster with
two node pools**, not a cluster per environment: GKE's free tier waives the
management fee for only **one** zonal cluster per billing account, so a second
cluster would add ~$74/mo and break the budget. dev/prod isolation is achieved
**in-cluster** instead of physically:

- a dedicated, **tainted** prod node pool (`e2-standard-2`, `dedicated=prod`) so
  dev workloads can never contend with prod for CPU/memory;
- an **untainted** dev node pool (`e2-small`) that also hosts `kube-system`
  (CoreDNS etc.), so the dev tenant and system pods share the cheap pool —
  **on-demand, not Spot**, because preempting this pool would take CoreDNS down
  for prod too;
- **namespace RBAC** (dev team scoped to the `dev` namespace only) and
  **default-deny NetworkPolicies** in `dev` (see `helm/developing/`), so the dev
  tenant cannot reach prod (or any other namespace) on the pod network.

| Line item | Config | ~$/mo |
|-----------|--------|-------|
| GKE control plane | 1 zonal cluster | $0 (free tier) |
| prod node pool | 1× `e2-standard-2`, on-demand | ~$49 |
| dev node pool | 1× `e2-small`, on-demand | ~$12 |
| prod Cloud SQL | `db-f1-micro`, 20Gi SSD, PITR + 7-day backups | ~$12–15 |
| prod GCS (filestore) | Standard, small | ~$2 |
| dev PVCs (in-cluster pg 5Gi + local filestore 10Gi) | pd-standard | ~$1 |
| Buffer (egress/growth) | | ~$10–15 |
| **Total** | | **~$86–93** |

Every cost/HA knob is a typed variable with a production-safe path:

| Concern | Default | Harden (flip a variable) |
|---------|---------|--------------------------|
| GKE control plane | Zonal (free-tier eligible) | `gke_regional = true` |
| prod nodes | 1× `e2-standard-2`, on-demand | bump `max_count` / machine type |
| prod Cloud SQL | `db-f1-micro`, `ZONAL`, PITR on | `db-custom-*`, `REGIONAL` (HA) |
| dev database | in-cluster Postgres (`cloudsql_enabled=false` for the dev tenant) | promote dev to managed Cloud SQL |
| Environments | one cluster, dev as a namespace tenant | add a separate cluster/deployment for a hard split |
| Control-plane access | `master_authorized_networks` (CI CIDR) | keep restricted |

Non-negotiable production practices are kept **even at this budget**: private
nodes + Cloud NAT egress, Workload Identity, Shielded Nodes, private-IP Cloud SQL
over Private Service Access, uniform bucket access + public-access prevention,
dedicated least-privilege service accounts, **all secrets in Secret Manager**,
and **customer-managed encryption (CMEK)** on by default — one shared Cloud KMS
HSM key across Cloud SQL, GCS, Secret Manager, and Artifact Registry.

**Dev/prod isolation on one cluster:** the tainted prod pool guarantees resource
isolation; `nodeSelector tier=prod|dev` on the Kubernetes manifests pins each tier to
its pool. On top of scheduling, the `dev` namespace gets default-deny ingress and
egress NetworkPolicies (allow only intra-namespace + DNS + egress to public IPs,
never to other in-cluster namespaces) and a namespace-scoped RBAC Role/RoleBinding
for the dev team — no cluster-scoped rights, no path to prod.

**GKE Standard vs Autopilot:** Standard is chosen because the target
architecture calls for explicit multiple node pools and node-level cost control
(machine type, disk, taints) that Autopilot abstracts away.

**Why the registry is its own component (not a separate stack):** a single
cross-environment registry has no natural home in a per-environment deployment,
but keeping it as an `artifact_registry` component in the one stack — next to the
`mattermost_image` CI that writes to it — is the simplest home. When the CI was a
separate stack, a platform-side writer binding would have created a
`platform <-> build` cycle; inside one stack the dependency is a plain component
reference and the cycle disappears. GKE nodes still pull with zero extra IAM
because the node SA holds project-level `artifactregistry.reader`.

## Dependency graph

One stack, one deployment (`prod-eu`), all components below:

```mermaid
graph TD
  PS[project_services<br/>enable ALL APIs] --> NET[network<br/>VPC/NAT/PSA + reserved ingress IP]
  PS --> STO[storage<br/>GCS + HMAC creds]
  PS --> SEC[secrets<br/>Secret Manager]
  PS --> AR[artifact_registry<br/>unified docker repo]
  PS --> IMG[mattermost_image<br/>2nd-gen connection + tag triggers]
  AR --> IMG
  NET --> SQL[cloudsql<br/>private PostgreSQL, prod]
  NET --> GKE[gke<br/>1 cluster, 2 node pools]
  NET -->|ingress_ip_address| CF[cloudflare<br/>proxied apex A + www + CAA<br/>TLS/security + DNSSEC + WAF<br/>Origin CA cert]
  WI[workload-identity<br/>GSA per tenant]
  WI -->|accessors| SQL
  WI -->|accessors| STO
  WI -->|accessors| SEC
  KMS[kms<br/>shared CMEK key] -->|encrypt| SQL
  KMS -->|encrypt| STO
  KMS -->|encrypt| SEC
  GKE --> CD[clouddeploy<br/>dev→prod delivery of helm/ workloads]
  CF -->|Origin CA cert/key| SEC
```

Ordering is expressed by components referencing each other's outputs — explicit
dependencies, no implicit ordering. Two former cross-stack hand-offs are now live
component references: the reserved `ingress_ip_address` flows straight into the
Cloudflare apex A record, and the Cloudflare Origin CA cert/key flow straight
into the `mattermost-origin-tls-*` secrets. Workload Identity SA emails flow into
the secret-owning components as least-privilege `secretAccessor` members. The one
`project_services` component enables every API the product needs; only a minimal
bootstrap set (auth + Service Usage + Secret Manager) and the `github-pat` secret
are done once in [`docs/INIT.md`](docs/INIT.md).

## Repository layout

```
terraform/                  # ONE Terraform Stacks configuration (the whole product)
  .terraform-version        # Terraform Core version pin (read by HCP Stacks + CI)
  .terraform.lock.hcl       # provider lock (all 5 providers, committed at the root)
  providers.tfcomponent.hcl # stack provider requirements: google, google-beta, random, cloudflare, tls
  variables.tfcomponent.hcl # typed stack input variables (GCP + build + cloudflare)
  components.tfcomponent.hcl # component wiring (one block per building block)
  outputs.tfcomponent.hcl    # stack outputs (platform + image CI + cloudflare)
  deployments.tfdeploy.hcl   # ONE `prod-eu` deployment (identity_token + cloudflare varset)
  modules/                  # small, single-purpose, reusable modules
    project-services/       # enable ALL Google APIs the product needs (one place)
    network/                # VPC, subnet(+secondary ranges), Router, NAT, PSA, reserved IP
    gke/                    # zonal Standard cluster + node_pools map + WI + CSI
    cloudsql/               # private PostgreSQL + DB + user + password/conn secrets
    storage/                # GCS bucket (+ optional Mattermost S3 HMAC creds)
    kms/                    # one shared Cloud KMS HSM key (CMEK) + service-agent grants
    clouddeploy/            # dev→prod delivery pipeline + 2 GKE targets + exec SA
    secrets/                # Secret Manager map (generate/provide + accessors)
    workload-identity/      # per-tenant GSA bound to a KSA (WI)
    artifact-registry/      # the unified Docker repo
    cloudbuild-image/       # 2nd-gen GitHub connection + repo + tag-triggered builds
    cloudflare/             # DNS records + edge TLS/security + DNSSEC + WAF + Origin CA cert / AOP
helm/                       # Kubernetes workloads, delivered by Cloud Deploy dev→prod
  skaffold.yaml             # dev/prod profiles Cloud Deploy renders (+ dev verify)
  cloudbuild.yaml           # illustrative: cut a Cloud Deploy release from helm/
  namespaces.yaml           # mattermost (prod) + matterbridge + dev tenants
  mattermost/               # prod: SA + SecretProviderClass + secret-sync + operator CR
  matterbridge/             # SA + SecretProviderClass + Deployment + NetworkPolicy (dev pool)
  developing/               # SA/SPC + in-cluster Postgres + dev Mattermost +
                            #   networkpolicy.yaml + rbac.yaml (tenant isolation)
    verify/                 #   on-cluster smoke-test Job template (dev-stage verify)
  ingress-nginx/            # Cloudflare-only ingress values + bootstrap runbook
.gitlab-ci.yml              # module fmt/validate + manifest lint
```

> Stack layout: the repo hosts **one** Terraform Stacks configuration at
> `terraform/`, using the `*.tfcomponent.hcl` (components, providers, variables,
> outputs) and `*.tfdeploy.hcl` (deployments) suffixes Terraform Stacks requires.
> HCP reads **one stack per working directory**, so there is a single HCP Stack
> with its working directory set to `terraform/`. Modules are co-located under
> `terraform/modules/` and referenced as `./modules/X`: the Stacks source bundler
> roots the bundle at the stack config directory and cannot follow `../` sources
> that escape it. The stack commits one `.terraform.lock.hcl` (covering all five
> providers) for reproducible runs.

> Version pin: HCP Terraform Stacks selects the Terraform Core version from the
> stack's **`.terraform-version`** file (currently `1.15.8`). The GitLab CI
> images are pinned to the same version so local, CI, and HCP runs agree.

> Separation of concerns: **infra** (Terraform) provisions cloud resources and
> **helm/** holds the chat workloads, delivered to the cluster by the Cloud
> Deploy dev→prod pipeline — infrastructure and workloads are kept apart.

## Deploying (HCP Terraform Stacks)

1. Create **one** GCP project with billing linked, or reuse an existing one.
   This slice does **not** create projects/org (that is a separate future
   foundation stack requiring org + billing permissions).
1. Run the one-time bootstrap in [`docs/INIT.md`](docs/INIT.md): enable the
   bootstrap APIs (auth + Service Usage + Secret Manager), create the Workload
   Identity Federation pool/provider and `terraform plan`/`apply` service accounts
   (with all IAM roles the stack needs), create the `github-pat` secret, and
   create the Cloudflare API token + HCP variable set. The stack enables every
   other API itself; these are the only manual prerequisites.
2. In `terraform/deployments.tfdeploy.hcl` the project ID (`yourown-chat`), WIF
   `audience` and apply-SA are already wired; set the real
   `master_authorized_networks` CIDR if you want to restrict the control plane
   (empty = reachable but credential-gated, so Cloud Deploy can reach it), set the
   real `github_app_installation_id`, and replace the `store "varset"` id with your
   HCP variable set ID.
3. Configure **keyless** GCP auth in HCP Terraform (no credentials are ever
   committed). The Workload Identity Federation pool/provider and least-privilege
   `terraform plan`/`apply` service accounts are documented in
   [`docs/INIT.md`](docs/INIT.md); the `audience` and `service_account_email`
   inputs are already wired to that setup. HCP mints the OIDC token via the
   `identity_token` block (its `aud` matches the provider's allowed-audiences); the
   google provider exchanges it through WIF (`external_credentials`) and
   impersonates the apply SA.
4. Create **one** Stack in HCP Terraform with its **working directory set to
   `terraform/`**, attach the Cloudflare variable set to it, then plan and apply
   the single `prod-eu` deployment. (An existing Stack that pointed at
   `terraform/platform` must be updated to this working directory after the
   reorg.) The one apply provisions the platform, the image CI **and** the
   Cloudflare edge together — the ingress IP and the Origin CA cert are wired
   internally, so there is nothing to copy between runs.
5. Deploy the chat workloads from [`helm/`](helm/README.md): install the
   ingress-nginx controller + Mattermost operator, replace the `REPLACE-ME-*`
   markers (project ID, bucket, Workload Identity SA emails from
   `terraform output workload_identity_emails`, the dev-team RBAC principal),
   then apply the manifests (namespaces, then per-tenant resources including
   `helm/developing/networkpolicy.yaml` and `helm/developing/rbac.yaml`).

The image-build flow (setting the Cloud Build App installation ID, the tag
pattern, promotion) is described in [`docs/BUILD.md`](docs/BUILD.md); it is part
of this same stack, so there is no separate stack to create.

## CI/CD flow

**Mattermost image (the `mattermost_image` component)** — build once, push to
the one unified registry, promote by tag:

```
git tag on github.com/pilprod/mattermost ──► Cloud Build (2nd-gen trigger)
   ^v.*-patched$   ─► build Dockerfile ─► push docker/mattermost:<tag>
```

- One Cloud Build 2nd-gen GitHub connection + repository watches the external
  Mattermost source repo; a single tag pattern (`^v.*-patched$`) builds **one**
  image, and that same artifact is deployed to dev and prod (promoted, not
  rebuilt per environment). Builds run as a dedicated, least-privilege runtime SA
  (`img-build`: repo-scoped AR writer + log writer only). The Terraform apply
  impersonates the least-privilege `terraform-apply@` SA. See
  [`docs/BUILD.md`](docs/BUILD.md).
- The resulting image is referenced in both Mattermost manifests: prod
  `helm/mattermost/mattermost.yaml` (`spec.image` + `version`), dev
  `helm/developing/mattermost-dev.yaml`.

**Delivery to GKE (the `clouddeploy` component)** — provisions a Cloud Deploy
**dev → prod** pipeline that delivers the `helm/` Kubernetes workloads: two GKE
targets (`europe-west3-dev`, `europe-west3-prod`) on the one cluster, each
rendering a Skaffold profile from [`helm/skaffold.yaml`](helm/skaffold.yaml). The
**dev** target deploys the dev tenant (in-cluster Postgres + dev Mattermost) and
matterbridge, then runs a post-deploy **`verify`** smoke test on the cluster; the
**prod** target deploys the operator-managed Mattermost, with **`requireApproval`**
gating promotion. The Mattermost image is **built once** by the `mattermost_image`
component and promoted by tag — dev and prod reference the same tag in-manifest,
so Cloud Deploy promotes the identical manifests rather than rebuilding. Because
the registry and CI are components of the same stack (not a separate one), the
registry writer binding is a plain component reference with no dependency cycle.

## Security considerations

- Least-privilege, per-purpose service accounts (node, image-build, deploy,
  per-tenant Workload Identity; a single Terraform plan/apply SA for the stack);
  the default compute SA is never used.
- Private GKE nodes; egress only via Cloud NAT; Workload Identity for every pod
  that touches GCP.
- **Dev tenant isolation:** namespace-scoped RBAC (dev team limited to `dev`, no
  cluster rights), default-deny ingress/egress NetworkPolicies in `dev`
  (Dataplane V2 enforced), and `automountServiceAccountToken: false` on the dev
  workload SA (the dev workloads never call the Kubernetes API).
- Cloud SQL private IP only (`ipv4_enabled = false`), `ENCRYPTED_ONLY` TLS.
- **Encryption (CMEK):** one shared Cloud KMS **HSM** key (FIPS 140-2 Level 3,
  90-day rotation) encrypts Cloud SQL, the GCS bucket, and Secret Manager.
  At-rest data is AES-256 regardless; CMEK moves key custody + lifecycle
  (rotation, disable, destroy = crypto-shred) to us. The `kms` component owns the
  key and grants each service agent `encrypterDecrypter`. The container registry
  is **public** and deliberately not CMEK-encrypted. Toggle via
  `cmek_enabled` / `kms_protection_level` (`HSM` → `SOFTWARE` for ~$0.06/mo).
- **All secrets in Secret Manager** — DB password + connection URI (cloudsql),
  GCS S3-compatible HMAC keys (storage), dev Postgres password + matterbridge
  config + Cloudflare origin material (secrets module), each secret replica
  encrypted with the shared CMEK key. None are surfaced as
  plaintext outputs; pods read them via the GKE Secret Manager CSI add-on, gated
  by per-tenant `secretAccessor` IAM (a workload can read only its own secrets).
- Public ingress: prod Mattermost is exposed at `yourown.chat` only through
  Cloudflare — ingress-nginx admits only Cloudflare source ranges and enforces
  Authenticated Origin Pulls (mTLS) + Full (Strict) TLS. dev has no public
  ingress. See [`helm/ingress-nginx/README.md`](helm/ingress-nginx/README.md).
- Buckets: uniform bucket-level access + public access prevention enforced.

## Future scalability

Modules are intentionally small so the rest of the platform vision (Vault,
Authentik, cert-manager, ExternalDNS, Prometheus/Grafana/Loki) slots in as **new
components** in the same Stack, and additional MCP servers as Kubernetes workloads +
Workload Identity tenants — no root-module rewrites. Mattermost and matterbridge
already run as Kubernetes workloads in [`helm/`](helm/). The network module is
hub-and-spoke-ready and provisions PSA for future private managed services. If the
budget later rises, a hard dev/prod split is one more `deployment` (or a second
cluster); hardening prod is flipping `gke_regional` / `cloudsql_availability_type`.
The unified registry is ready for more images (add a build to the `builds` map).

## Decisions made autonomously — please review

These reflect the decisions we converged on; each is easy to change:

1. **Region:** `europe-west3` (Frankfurt) over `europe-west10` (Berlin) —
   cheaper and more mature. One-variable change.
2. **Topology:** **one** zonal cluster with two node pools; dev is an isolated
   **namespace tenant** (RBAC + NetworkPolicy), not a second cluster. Keeps the
   ~$86–93/mo budget under the $100 ceiling while isolating dev from prod.
3. **Registry + CI:** a **single unified** Artifact Registry repo (`docker`) as an
   `artifact_registry` component; one Mattermost image promoted dev->prod by tag.
   Kept in the one stack next to the CI that writes to it — no dependency cycle.
4. **Delivery:** a Cloud Deploy **dev→prod** pipeline delivers the `helm/`
   workloads (two GKE targets on the one cluster, dev `verify` + prod approval);
   the Mattermost image is built once and promoted by tag, so both tiers deploy
   the same manifests.
5. **Scope:** provisions into an **existing** `project_id`; org/project bootstrap
   deferred to a foundation stack.
6. **Cloud SQL:** prod only — `db-f1-micro` + PITR + 7-day backups, no HA (HA
   alone would consume most of the budget). The dev tenant uses in-cluster
   Postgres.
7. **Apps:** prod Mattermost via the operator CR (external Cloud SQL + GCS
   filestore); dev Mattermost + matterbridge as lightweight Deployments. Confirm
   the Mattermost operator version, ingress host, and matterbridge bridges.
8. **Auth model:** keyless OIDC -> WIF is wired (`external_credentials`) with the
   real `audience` and apply SA from `INIT.md`; the stack impersonates the
   least-privilege `terraform-apply@`. Cloudflare (no WIF path) uses a single
   zone-scoped API token from an HCP variable set, kept isolated from GCP.
9. **Encryption (CMEK):** one shared Cloud KMS **HSM** key (FIPS 140-2 Level 3,
   ~$1/mo, 90-day rotation) encrypts Cloud SQL + GCS + Secret Manager, on by
   default (the public Artifact Registry is deliberately not CMEK-encrypted). HSM
   (not SOFTWARE) is chosen so the expensive-to-change Cloud SQL key is right the
   first time — the instance binds its key at creation, so switching later means
   an instance migration. Flip `cmek_enabled = false` or
   `kms_protection_level = "SOFTWARE"` (~$0.06/mo) if you don't need FIPS L3.
