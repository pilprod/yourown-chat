# MCP integrations

The platform consumes MCP (Model Context Protocol) servers in two ways:

1. **In-cluster (self-hosted)** — deployed by the `mcp` Helm chart
   (`helm/mcp`), rendered onto the prod stage by Cloud Deploy when the
   app-gcp stack sets `mcp_servers_enabled = true`. Each server is an entry in
   `helm/mcp/values.yaml` (`servers.<name>.enabled`). Production is reachable
   across namespaces only from the Cloudflare Tunnel connector. Mattermost,
   Claude and ChatGPT use the common `https://tools.yourown.chat/mcp` Portal
   and never call an MCP ClusterIP. Every server
   has its own default-deny namespace (`mcp-terraform-stacks` or
   `mcp-google-cloud`), so a compromised server
   cannot initiate traffic to another MCP server. Each server admits only the
   Cloudflare Tunnel connector in the separate `mcp-tunnel` namespace. Egress is limited
   to cluster DNS plus encrypted external API/Tunnel traffic.
   Credentials are mounted directly from regional, CMEK-protected Secret
   Manager containers through the managed GKE CSI add-on. Each server has a
   dedicated Workload Identity and `SecretProviderClass`; operator-supplied
   HCP Terraform values never enter app-gcp state, Cloud Deploy, a Kubernetes
   Secret, or etcd. (The Cloudflare-generated Tunnel token necessarily remains
   sensitive state in the stack that creates it.) After adding a new
   `versions/latest`, restart only that server's Deployment to remount it; no
   Terraform apply or MCP release is required.
   Disposable `dev-mcp-*` instances instead share the quota-bound `dev`
   namespace with dev Mattermost and dev Postgres. They use the `development`
   PriorityClass and the tenant's default-deny/intra-namespace policies. Each
   dev server keeps its own KSA and the same per-server Secret Manager IAM
   boundary as production.
2. **Vendor-hosted (remote)** — the vendor runs the MCP endpoint; agents
   connect to its URL with OAuth. Nothing to deploy or operate on our side.
   Preferred whenever an official remote endpoint exists.

## Google Cloud Agent Registry

Agent Registry is the discovery/governance catalog for these integrations; it
does not host, proxy, authenticate to, or keep an MCP process alive.
`platform-gcp` enables `agentregistry.googleapis.com`.

Production GKE MCP Deployments carry the supported discovery metadata:

- `registry.gke.io/functional-type: MCP_SERVER`;
- `modelcontextprotocol.info/urls` and
  `modelcontextprotocol.info/capabilities`;
- `iam.gke.io/spiffe-identity-type: agent-identity` on the Pod template.

GKE therefore registers and introspects Terraform Stacks and Google Cloud MCP
after their production rollout. The dev overlay deliberately
disables registration because those instances are disposable and are scaled
to zero after review. Official Google remote MCP servers are registered
automatically when their APIs are enabled.

The independent `terraform/agent-registry-gcp` HCP Stack uses Google provider 7.x
without forcing the platform/app stacks off their pinned 6.x line. It
registers the public interfaces already used by agents:

| Registry kind | Entry | Interface |
|---|---|---|
| Endpoint | Mattermost API | `https://yourown.chat/api/v4` |
| Endpoint | HCP Terraform API | `https://app.terraform.io/api/v2` |
| MCP server | Meta Developer Tools MCP | `https://mcp.facebook.com/devtools` |

Apply `platform-gcp` first and then `agent-registry-gcp`. The Terraform apply SA
needs `roles/agentregistry.editor`; existing environments can grant it once:

```bash
gcloud projects add-iam-policy-binding yourown-chat \
  --member=serviceAccount:terraform-apply@yourown-chat.iam.gserviceaccount.com \
  --role=roles/agentregistry.editor
```

The external Meta MCP is registered with `NO_SPEC`: its endpoint is
catalogued, but Agent Registry does not automatically import tools from an
OAuth-protected third-party endpoint. Authentication and tool authorization
still happen with Meta.

After the Agent Registry stack and the production MCP release are applied,
verify both discovery paths:

```bash
gcloud agent-registry endpoints list \
  --project=yourown-chat \
  --location=europe-west3

gcloud agent-registry mcp-servers list \
  --project=yourown-chat \
  --location=europe-west3
```

The two GKE servers should expose discovered tools after introspection. The
manually registered Meta entry is expected to show endpoint metadata without a
Terraform-managed tool specification.

## Integration matrix

Status of every requested integration. "Community" servers are third-party
code: pin images deliberately, review before enabling, and expect API-ToS
constraints (especially for consumer services without a public API).

### Live in-cluster

| Service | Server | Credentials |
|---|---|---|
| Terraform Stacks management | internally built `mcp-terraform-stacks` adapter over the official HCP Terraform Stacks API; guarded stack settings, configuration lifecycle, deployment inspection, run-scoped approve/cancel and safe stack deletion | HCP user token in Secret Manager (`mcp-terraform-hcp-token`, placeholder seeded), with Project Maintain or higher and its owner authorized for the repository's HCP GitHub App |
| Google Cloud (Observability + Artifact Analysis + guarded Cloud Deploy lifecycle) | internally built static Go `mcp-google-cloud` server using the official Tier-1 MCP Go SDK | **none — keyless**: separate Workload Identity principals for prod lifecycle and disposable read-only dev; quota project is `yourown-chat` |

The private `pilprod/yourown-chat-mcp` repository contains both Go commands and
their tests. This public platform contains only one hardened, parameterized
`docker/mcp/Dockerfile`, Terraform, Helm and lifecycle documentation. The Go
server implements the observability tool catalog and adds
Cloud Deploy lifecycle, Artifact Analysis, Billing Export, Budgets, and
Recommender tools. Every observability resource is additionally constrained to
the configured project; workload credentials cannot be redirected to another
project through a caller-supplied resource name. Custom protocol
names omit the server identity (`build_list_builds`, not
`google_cloud_build_list_builds`) because Cloudflare Portal already namespaces
them with `google-cloud`. This prevents duplicated client labels while
structured titles remain `Google Cloud · Build · List builds`.
The scratch runtime contains only a static binary and CA roots; there is no
package manager, shell, writable dependency cache or init container.

Pushes and immutable source tags in `pilprod/yourown-chat-mcp` run formatting,
module verification, vet, race tests and `govulncheck`, then build both images
with the public unified Dockerfile. BuildKit emits SBOM/provenance and Google
On-Demand Scanning blocks HIGH or CRITICAL findings. Only an immutable
`X.Y.Z` source tag can create an MCP release. The trigger
resolves the selected digest and passes
`mcp_google_cloud_image=<repository>@sha256:...` to Cloud Deploy, so both dev
and prod promote the exact same artifact. Paid automatic Artifact Analysis
scanning is disabled by default; `platform-gcp` keeps only the API ready and
sets the repository gate to `DISABLED`.

The first-party security adapter exposes only the committed
`yourown-chat/europe-west3/docker` repository:

- `security_list_images` lists immutable digest pages with tags,
  sizes, timestamps, discovery status, available-fix count, and vulnerability
  counts by severity for every returned image;
- `security_list_vulnerabilities` returns complete vulnerability
  occurrences for one digest, including CVE/GHSA ID, effective severity, CVSS
  score, remediation, affected/fixed package versions, and the raw occurrence;
- `security_get_vulnerability` returns the occurrence plus its
  provider Note, including the advisory description, CVSS vectors, related
  URLs, affected versions, and remediation metadata available from Google.
- `security_get_scanning` reads the repository scanning config and effective
  state;
- production-only `security_set_scanning` changes the allowlisted repository
  between `DISABLED` and `INHERITED`. It requires optimistic expected state,
  an exact enable/disable confirmation and an audit reason, and is presented to
  clients as a write/destructive action requiring approval.

The inventory and finding tools are read-only. Image URIs must use an allowlisted repository
and immutable `@sha256:` digest; occurrence names must belong to the configured
project. The production identity holds `roles/artifactregistry.reader`,
`roles/containeranalysis.occurrences.viewer` and a custom role containing only
`artifactregistry.repositories.get/update`; it cannot delete images or
repositories.

For a paid scan, read state, enable scanning, push only the intended build
digests, wait for discovery, inspect findings, and disable scanning again.
Enabling the gate does not guarantee a fresh scan of every old digest, so an
existing image that requires a new assessment must be rebuilt or re-pushed as
a new immutable digest during the window. Stored findings remain queryable
after disabling. The Terraform baseline is also `DISABLED`, so an unrelated
platform apply closes a forgotten scan window.

The cost adapter is also read-only:

- `billing_get_profile` reports the project-to-billing-account association and
  whether a Detailed Billing Export table is configured;
- `billing_list_budgets` returns budget scope, amount, period, actual/forecast
  thresholds, and Pub/Sub notification configuration;
- `billing_analyze_costs` aggregates the Detailed usage cost export by day,
  service, SKU, project, location, resource, invoice month, or cost type. It
  returns gross/list/effective/net cost, credits, attribution, and BigQuery
  execution statistics;
- `billing_list_recommendations` collects Active Assist cost recommendations
  for Compute Engine, GKE, Cloud SQL, Cloud Run, Storage, and BigQuery,
  including projected savings and affected resources.

Cost queries never return raw export rows. They use named date parameters,
return at most 200 aggregated rows, time out after 30 seconds, and set
`maximumBytesBilled=1 GB`, so a broader query fails before incurring excess
BigQuery scan cost. Enable **Detailed usage cost export** in Cloud Billing,
grant `mcp-servers@yourown-chat.iam.gserviceaccount.com`
`roles/bigquery.dataViewer` on that billing dataset, and set
`GOOGLE_CLOUD_BILLING_EXPORT_TABLE` to the exact
`project.dataset.gcp_billing_export_resource_v1_ACCOUNT` table. The platform
Stack now creates the EU multi-region dataset `yourown-chat.billing`, grants
the MCP reader, enables GKE cost allocation, and configures the expected table
name. The only remaining one-time action is Billing → Billing export →
BigQuery export → Detailed usage cost → Enable: select project `yourown-chat`
and dataset `billing`, then save. Google creates
`gcp_billing_export_resource_v1_01B729_537989_CCA4BB`; initial EU backfill can
take up to five days and starts at the beginning of the previous month. The
one-time toggle is not available through Terraform or `gcloud`. Billing account
budgets additionally require `roles/billing.viewer` for that GSA on the linked
billing account; this account-scoped grant cannot be derived from project IAM.
Without the table, profile/budget/recommendation tools remain usable and cost
analysis returns an explicit configuration error.

Detailed usage cost is the required export because it includes Standard fields
plus resource attribution. Standard is redundant for this adapter. Pricing
data is useful for forecast and contract-price comparisons but is not
retroactive; CUD metadata is useful only after commitments are purchased.
FOCUS (Preview) is useful for future normalized multi-cloud reporting but does
not replace the native Detailed export used for GCP resource optimization.

The static Go server terminates Streamable HTTP directly and performs bounded
Google REST calls without subprocesses. This removes the old stdio child and
per-session Node.js process overhead. The container keeps its existing memory
headroom for large Logging, Artifact Analysis and BigQuery JSON responses, but
the Go transport caps every incoming MCP body at 1 MiB and API clients apply
bounded response and query limits.

Keep Observability calls bounded even with this headroom:

- `list_log_entries`: include an indexed `resource.type` or exact `logName`, an
  explicit timestamp interval, `orderBy: "timestamp desc"`, and `pageSize` no
  larger than 20;
- expand using `pageToken` or short adjacent time windows instead of a broad
  project-wide query;
- avoid project-wide `list_log_names` during routine diagnostics; use the
  known log name or resource type;
- bound monitoring and trace calls with narrow time intervals and small page
  sizes as well.

Cloud Build and Cloud Deploy management are deliberately narrower than general
Google Cloud administration:

- fixed project `yourown-chat` and location `europe-west3`;
- Cloud Build access is read-only: list builds, inspect complete step/result
  state, and read build-scoped Cloud Logging entries;
- only the `mattermost`, dev-only `mattermost-preview`, and `mcp` pipelines
  and their committed targets are accepted; `mattermost-preview` exposes only
  `mattermost-preview-dev` and therefore cannot be promoted to production;
- releases, rollouts, phases, and their deploy/verify/pre/post job runs can be
  listed and inspected without the Cloud SDK;
- promotion is a two-call `plan_promote` → `promote` flow and requires the
  exact SHA-256 plan ID plus literal `PROMOTE`;
- approval requires a fresh rollout inspection, its exact etag, a reason, and
  literal `APPROVE`;
- rejection uses `deploy_reject_rollout`: it scales only the pipeline's
  RBAC-allowlisted dev Deployments to zero, verifies desired and observed
  replicas are zero, revalidates the rollout etag, and only then rejects it;
- `deploy_cleanup_dev` performs the same guarded scale-to-zero for an
  experimental release that never created a production rollout;
- `deploy_inspect_dev_scale` confirms cleanup after rejection or rollback;
- releases annotated `release-channel=experimental` (source tags
  `vX.Y.Z-dev.N`) cannot be promoted to a `*-prod` target through this MCP;
- rollback is a two-call `plan_rollback` → `rollback` flow. The plan uses
  Cloud Deploy's `validateOnly` API, and execution requires its exact SHA-256
  plan ID plus literal `ROLLBACK`;
- an existing pending, active, or successful rollout for the same
  release/target blocks another promotion.

The Workload Identity GSA has the read-only
`roles/cloudbuild.builds.viewer`, plus `roles/clouddeploy.releaser` and
`roles/clouddeploy.approver`. Existing `roles/logging.viewer` grants access to
the build's Cloud Logging records. Terraform grants `serviceAccountUser` only
on the two pipeline execution/cleanup identities; the MCP cannot impersonate
unrelated service accounts. Release creation remains owned by the tag-triggered
Cloud Build pipeline. The dev pod uses `mcp-observability-dev`, which has only
Logging, Monitoring, Trace, Artifact Registry, and Artifact Analysis read
access; build and mutating lifecycle tools are not advertised.

Operational agents must use these MCP tools for build/deploy state and actions:

1. `build_list_builds` and `build_inspect_build`;
2. `build_list_build_logs` for failed or incomplete steps;
3. `deploy_list_releases` and `deploy_inspect_release`;
4. `deploy_list_rollouts`, `deploy_inspect_rollout`, and
   `deploy_list_job_runs`;
5. guarded plan/promote, inspect/approve, or plan/rollback flows.

The Cloud SDK remains only a human bootstrap/debugging fallback. Agents must
not use `gcloud builds ...` or `gcloud deploy ...` when the production Google
Cloud MCP is available.

The Go server clamps page sizes and rejects resource names outside its
configured project. Callers must still supply narrow time intervals because a
small result page can require a broad and expensive upstream scan.

Inspect deployed image digests and findings with
`security_list_images`, then pass the selected immutable URI to
`security_list_vulnerabilities`. Use `security_get_vulnerability` for the complete occurrence and
provider advisory.

Artifact Analysis updates findings for an existing digest as its vulnerability
database changes. A rebuild is required only to consume fixed Go or OS
dependencies.

`docker/base/Dockerfile` produces the internally scanned
`base` image from a pinned Alpine digest and installs all available package
updates during the build.
`docker/base/node.Dockerfile` and `docker/base/python.Dockerfile` create the
language runtimes on top; application Dockerfiles consume only
`RUNTIME_IMAGE`. This centralises CA certificates, the non-root UID, OS
packages, and runtime policy without adding Node to the Python image.
The Node runtime contains the `node` executable but not npm, npx, Corepack, or
their package-management dependency trees; each application resolves its lock
file in a disposable build stage and copies only production `node_modules`.
The Python runtime copies the official standalone `uv` binaries and does not
carry pip/setuptools metadata.

`docker/images.tsv` is the single image catalog for built and mirrored images.
Public vendor rebuilds use `docker/prepare-images.sh`,
`docker/audit-images.sh`, and `docker/build-images.sh`. First-party MCP Go
source follows the independent private-source lifecycle described above.
Mattermost remains on its upstream image. Cloudflared is
compiled from
the unmodified commit behind the pinned official release tag with a patched
pinned Go toolchain and copied into the same pinned distroless runtime family
used upstream.

For a local MCP build, use the private source checkout as the build context and
this public Dockerfile:

```bash
docker build -f ../yourown-chat/docker/mcp/Dockerfile \
  --build-arg SERVICE=terraform-stacks \
  -t mcp-terraform-stacks:local ../yourown-chat-mcp
```

`docker/mcp/upstreams.env` is the reviewable upstream lock for the other
runtime images. Cloudflared 2026.7.3 is checked out at commit
`3a2b45c2a511fcdd81b68c190938e4ffadbea5dc` and rebuilt with Go 1.26.6
rather than the vulnerable Go 1.26.4 used by the upstream container.
Every in-cluster workload is rendered with an Artifact Registry `@sha256`
reference.

#### HCP Terraform token

Create a **user API token** in HCP Terraform for a dedicated operator whose
account has Project Maintain (or higher) on `yourown-chat` and has authorized
the HCP Terraform GitHub App used by `pilprod/yourown-chat`. HCP rejects
GitHub App-backed Stack creation/update with team or organization API tokens,
even when their project permissions are otherwise sufficient. This token is a
shared runtime identity for every chat user of the server, so the MCP's
committed project/repository/directory allowlists remain mandatory. Then add a
new Secret Manager version:

```bash
printf '%s' "<user-api-token>" | gcloud secrets versions add mcp-terraform-hcp-token --data-file=-
# No Terraform apply or release is required; restart the CSI consumer:
kubectl -n mcp-terraform-stacks rollout restart deploy/mcp-terraform-stacks
```

The server reads the target address only from its own `TFE_ADDRESS` env
(`https://app.terraform.io`); attempts to override it per-request are rejected,
so chat input cannot repoint the server at another Terraform instance.

The adapter separates **Stack management** from **deployment approval**.
Creation and settings updates are constrained to the committed policy:

- organization `papou-work`;
- project `prj-QuYKhn6EzLX9jB53`;
- repository `pilprod/yourown-chat` through the existing HCP GitHub App;
- relative working directories below `terraform/`;
- remote execution and a trigger pattern scoped to that working directory.

`plan_create` and `plan_update` are read-only
previews that return a SHA-256 plan ID. Their mutating counterparts repeat the
full input, recompute the plan against current HCP state, require the exact
plan ID, and require `CREATE_STACK` or `UPDATE_STACK`. The update tool cannot
move a Stack to another project/repository, rename it, change execution mode,
or delete it. Creation can optionally fetch the first VCS configuration but
does not alter the approval allowlist.

Deployment approval remains narrower. Stack IDs inside organization
`papou-work` must satisfy the same project, repository, and directory policy
and are then resolved from the committed name allowlist:

- `cloudflare`;
- `app-gcp`;
- `platform-gcp`;
- `keycloak`;
- `agent-registry-gcp`.

`agent-registry-gcp` may be absent until that HCP Stack is created or the
existing catalog Stack is renamed; it becomes available automatically once its
name matches. Approval requires the exact `sdr-*` run ID, the exact `stc-*`
configuration ID returned by the inspection tool, a reason, and the literal
confirmation `APPROVE`. The adapter verifies that the run belongs to the named
allowlisted Stack and has a plan step in `pending_operator`, then calls the
run-scoped endpoint with `all_plans=false`. It never exposes deployment-group
approval or approval of later plans.

Available management tools:

- `list_stacks`;
- `get_stack_settings`;
- `list_configurations` / `inspect_configuration` for configuration status,
  preparation diagnostics, and deployment-group summaries before a run exists;
- `plan_create` / `create`;
- `plan_update` / `update`;
- `plan_configuration` / `create_configuration`, including guarded
  `fetch`, `reuse`, and destroy-all configurations;
- `plan_delete` / `delete`, which refuse deletion while any deployment
  remains.

Available delivery tools remain:

- `list_deployment_runs`;
- `inspect_deployment_run`;
- `approve_deployment_run`;
- `cancel_deployment_run`.

`inspect_deployment_run` deliberately returns only resource addresses, action
types, step status, and diagnostic severity. Terraform values, output values,
raw plan artifacts, and diagnostic text are omitted even when HCP marks them
non-sensitive. This prevents state-backed credentials from crossing the MCP
boundary while preserving the exact resource/action list required for an
approval decision.

Rollout order for the Google Cloud server: apply **platform-gcp first** (creates
the `mcp` GSA + Workload Identity binding and publishes it in
`workload_identity_emails`), then app-gcp (injects the GSA into the KSA
annotation via the `mcp_google_cloud_gsa` deploy parameter), then a release.

#### Official Google Workspace remote MCP

Google provides vendor-hosted remote MCP servers for Gmail, Calendar, and
Drive. They replace the previous community `google_workspace_mcp` workload:
there is no Workspace image, pod, namespace, Kubernetes Secret, tunnel route,
or credential smoke in this repository.

The `platform-gcp` stack enables both the product API and MCP API for each
service:

- Gmail: `gmail.googleapis.com`, `gmailmcp.googleapis.com`;
- Calendar: `calendar-json.googleapis.com`, `calendarmcp.googleapis.com`;
- Drive: `drive.googleapis.com`, `drivemcp.googleapis.com`.

These services are in Google Workspace Developer Preview. Enrol the Google
Cloud project in the preview if the console requests it, configure the Google
Auth Platform consent screen, then create a **Web application** OAuth client.
Register this exact Mattermost Agents callback:

```text
https://yourown.chat/plugins/mattermost-ai/oauth/callback
```

The disposable dev instance uses:

```text
https://dev.yourown.chat/plugins/mattermost-ai/oauth/callback
```

Both callbacks are allow-listed in the Cloudflare Portal Managed OAuth
configuration. Mattermost itself connects only to
`https://tools.yourown.chat/mcp`; it never receives a direct MCP ClusterIP.

The OAuth client ID and secret are entered in Mattermost's MCP server settings,
not placed in Kubernetes. Mattermost stores a separate OAuth token for every
user, so each user must click **Connect** and grant their own Google access.
Use the smallest scopes required by the enabled tools and require confirmation
for tools that send mail, change calendars, or create/copy Drive files.

#### Meta Developer Tools

Meta now publishes the official, beta **Meta Developer Tools MCP** at
`https://mcp.facebook.com/devtools`. It covers developer-platform operations:
app configuration and diagnostics, API health, App Review/compliance,
documentation/changelog search, and webhook subscription administration. It
is vendor-hosted and independently registered in Google Cloud Agent Registry;
there is no corresponding GKE workload or credential in this repository.

## Connect the Cloudflare MCP Portal and Google Workspace to Mattermost

Open **System Console → Plugins → Agents → MCP Servers** (the label can be
**Remote MCP Servers** in some plugin versions), add the server, save, then
enable it for the required agent.

Add exactly one self-hosted gateway:

- Name: `yourown-chat tools`
- Enabled: `true`
- Server URL: `https://tools.yourown.chat/mcp`
- Headers: empty
- OAuth credentials: empty

Save it, then select **Connect** from Mattermost web or desktop and complete
Cloudflare Managed OAuth. Each Mattermost user connects separately. This
identifies the user at the Portal boundary; the current upstream mapping still
uses shared workload credentials (`on_behalf = false`). Never paste a
Cloudflare service token, HCP Terraform token, or Google service-account key
into Mattermost.

Delete former direct Terraform Stacks and Google Cloud entries after the
Portal connection exposes their tools. Their
ClusterIP names are intentionally blocked by NetworkPolicy and are no longer
allowlisted by Mattermost SSRF settings.

For Google Workspace add three separate remote servers. Use the same Web OAuth
client ID and secret for each:

| Name | Server URL |
|---|---|
| `Gmail` | `https://gmailmcp.googleapis.com/mcp/v1` |
| `Google Calendar` | `https://calendarmcp.googleapis.com/mcp/v1` |
| `Google Drive` | `https://drivemcp.googleapis.com/mcp/v1` |

Set `Enabled` to `true`, leave headers empty, and fill the OAuth client ID and
client secret under **OAuth Credentials**. Save each server, enable the desired
tools for the agent, then click **Connect** from Mattermost web or desktop and
complete Google consent. There is no Cloudflare Access step for these three
endpoints because Mattermost connects directly to Google.

### Official vendor-hosted remote — connect, nothing to deploy

| Service | Remote endpoint | Auth |
|---|---|---|
| Gmail | `https://gmailmcp.googleapis.com/mcp/v1` | Google OAuth, per Mattermost user |
| Google Calendar | `https://calendarmcp.googleapis.com/mcp/v1` | Google OAuth, per Mattermost user |
| Google Drive | `https://drivemcp.googleapis.com/mcp/v1` | Google OAuth, per Mattermost user |
| Cloudflare | `https://docs.mcp.cloudflare.com/sse` + per-product endpoints (bindings, observability, …) | OAuth (Cloudflare account) |
| Figma | `https://mcp.figma.com/mcp` | OAuth |
| Miro | `https://mcp.miro.com/` | OAuth |
| Jira Cloud (Atlassian) | `https://mcp.atlassian.com/v1/sse` | OAuth |

### Community self-hosted — candidates for the chart, need credentials + review

| Service | Candidate server | Credentials needed | Notes |
|---|---|---|---|
| Google Maps | reference `server-google-maps` (stdio) | Maps API key | stdio → needs a streamable-http gateway wrapper |
| Telegram | community MTProto/Bot-API MCP | bot token or MTProto session | Bot API variant is the safer path |
| Binance / Kraken / Bybit | community CCXT-based MCP | exchange API keys (read-only recommended) | one CCXT server covers all three |
| Airbnb | community `@openbnb/mcp-server-airbnb` (stdio, search-only) | none | stdio → gateway wrapper; search/browse only, no booking |
| SoundCloud | community (thin) | OAuth | API access is restricted/waitlisted; low maturity |
| X.com (Twitter) | community MCP over paid API | paid API key | API pricing gates real use |
| Facebook | community MCP over Graph API (pages/ads only) | Meta app + token | personal-profile access is not exposed by Meta |
| LinkedIn | community (scraper-based mostly) | — | official API is partner-gated; scrapers violate ToS — not recommended |
| iCloud Calendar | community `@icloud-calendar-mcp/server` | Apple ID + app-specific password | CalDAV bridge; third-party code receives account credentials |
| iCloud Drive | community `@instacodeio/icloud-drive-mcp-server` | local macOS iCloud session | local-only bridge over `~/Library/Mobile Documents`; requires Full Disk Access |

Apple does not provide an official iCloud MCP server. The two community
options above are intentionally not deployed: the Calendar bridge requires an
app-specific Apple password, while the Drive bridge depends on a logged-in Mac
and local filesystem access. Reconsider them only as a separately reviewed
personal/local integration, not as a production cluster service.

### No viable MCP / public API today

| Service | Why |
|---|---|
| Booking.com | partner-only API (affiliate program), no public/personal API |
| Trip.com | same — partner/affiliate only |
| Uber | public API discontinued for new apps; no personal-account API |
| RedotPay | no public API |
| Apple Music | MusicKit requires Apple Developer program + user tokens; no maintained MCP server |

## Zero Trust: private MCP services for people, not the public

The internal MCP servers have no network exposure outside the dedicated `mcp`
namespace. Zero Trust moves the perimeter to the Cloudflare edge so authorised
people reach them without making anything public:

```
MCP client / browser → Access policy (allowed emails, Google SSO / one-time PIN)
  → Cloudflare Tunnel (outbound-only cloudflared pod, `mcp-tunnel` namespace)
  → ClusterIP in that server's own namespace
```

Everything fits the Zero Trust **Free** plan: 50 seats. Interactive Mattermost,
Claude and ChatGPT users authenticate to the Portal; tunnel and Access apps are
free. Cloudflare OAuth tokens do not consume LLM/API tokens;
the limits and subscription of the MCP client itself are separate.

The layer ships **enabled** (`zero_trust_enabled = true` in both stacks,
`tunnel.enabled: true` in the chart, allowed emails committed); the account ID
is derived from the zone lookup. The flags are the kill switch for the
external private-service path. Mattermost traverses the same Portal as every
other interactive MCP client, so its namespace has no direct path to an MCP
namespace.

### Human clients use Portal OAuth; Cloudflare uses a service token upstream

Claude and ChatGPT connect only to the MCP Portal. Terraform enables Managed
OAuth and dynamic client registration on the Portal's `type = "mcp_portal"`
Access application. It permits loopback callbacks plus the hosted Claude,
ChatGPT, Cloudflare Playground, and shared Cloudflare callback URIs. Access
tokens currently use a temporary 24-hour Codex compatibility window; the
security baseline remains 15 minutes. Grants last two weeks. The exception,
risk, upstream issues, and mandatory rollback test are documented in
[Cloudflare operations](CLOUDFLARE.md#temporary-24-hour-codex-compatibility-window).

Do **not** distribute `CF-Access-Client-Id` /
`CF-Access-Client-Secret` to ChatGPT, Claude, phones, or user laptops. Access
service tokens are shared machine identities. Terraform creates one temporary
shared token for Cloudflare AI Controls itself and stores its headers in the
upstream server registrations. Interactive clients use the Portal browser
login and receive an opaque, refreshable user token.

The direct MCP hostnames remain `self_hosted` Access applications. They do
not expose Managed OAuth to clients: AI Controls reaches them with the service
token under a `Service Auth` policy. This edge credential does not change the
downstream identity used by a server: Google Cloud MCP still calls Google
Cloud through its shared GKE Workload Identity service account, while
Terraform Stacks MCP still uses its configured HCP credential.

The Cloudflare stack uses provider 5.22.x, registers every configured server in AI
Controls, and creates a single `https://tools.yourown.chat/mcp` MCP Portal. This
matters for Claude Free, which permits one custom connector: one portal exposes
all servers through that connector. The Portal uses Managed OAuth and a
proxied CNAME to `gateway.agents.cloudflare.com`. Terraform explicitly manages
the Portal's `type = "mcp_portal"` Access application, policy, and Managed
OAuth; do not create a second Stack that owns the same objects.

Client availability is not identical:

- Claude remote connectors work from claude.ai, Claude Desktop, and mobile;
  Claude Free currently permits one custom connector. Add it from the web
  settings once; all clients use the cloud-hosted connection.
- ChatGPT custom MCP apps are currently web-only. Pro can use read/fetch MCP
  tools; full MCP including write actions requires Business or Enterprise/Edu.
- WARP is not required for either path. The MCP client connects from the
  vendor's cloud to the public Cloudflare edge, then Tunnel reaches the private
  ClusterIP.

### Rollout (in order)

1. **Prerequisite Terraform cannot do**: edit or re-issue the Cloudflare API
   token with ACCOUNT permissions `Cloudflare Tunnel:Edit` + `Access: Apps and
   Policies:Edit` + `Access: Service Tokens:Edit` + `Access: Organizations,
   Identity Providers, and Groups:Edit` + `MCP Portals:Edit` (keep the existing
   zone permissions), update the varset — BEFORE applying, or the cloudflare
   apply fails on authorization. The stack adopts the existing Zero Trust
   organization and renames its team/domain to `yourown-chat` /
   `yourown-chat.cloudflareaccess.com`; clients using the old
   `yellow-sunset-672e.cloudflareaccess.com` domain must be updated.
2. Apply **platform-gcp**: create one Workload Identity per MCP runtime.
3. Apply **cloudflare**: create/update the tunnel, its Secret Manager token,
   DNS and Access apps. It also copies the dedicated account token carrying
   only `MCP Portals:Edit` into the CMEK-encrypted
   `cloudflare-mcp-capability-sync` secret through the Google provider's
   write-only argument; the token remains absent from Terraform state. Only
   the `deploy-mcp` Cloud Deploy identity can read this copy.
4. Apply **app-gcp**: grant the Terraform Stacks identity access to its HCP
   token container and create the MCP namespaces. The
   capability-sync action is attached to every successful production rollout.
5. Release: Cloud Deploy creates KSAs + SecretProviderClasses and the pods
   mount `versions/latest` directly. A release racing ahead of the IAM steps
   waits in `ContainerCreating`; re-run it after the stack applies.
6. Terraform supplies the Access service-token headers to all AI Controls
   registrations. No upstream browser authorization is required. Every
   successful production MCP rollout runs the guarded postdeploy capability
   sync, so renamed and newly added tools become visible immediately instead
   of waiting for Cloudflare's background refresh. The action also fails if
   the Google Cloud security inventory and scanning-control tools are missing
   from the refreshed catalog. Treat an OAuth grant loss after this action as
   a reproducible defect and retain the postdeploy logs; do not silently
   disable synchronization. See
   [`CLOUDFLARE.md`](CLOUDFLARE.md).

### Connect personal clients

Use the single Portal endpoint in every remote client:

```text
https://tools.yourown.chat/mcp
```

For Claude Free, Pro, or Max:

1. In `claude.ai`, open **Customize → Connectors**.
2. Select **+ → Add custom connector**.
3. Name it `yourown-chat`, paste the Portal URL, and leave optional static
   OAuth client credentials empty.
4. Select **Connect** and complete the single Cloudflare Access login for the
   Portal. Upstream servers use the administrator credential and do not prompt
   the client for another authorization.
5. Enable the connector for a conversation from **+ → Connectors**. The same
   account connection is then usable from Claude Desktop and mobile; a new
   connector cannot be added from mobile itself.

For ChatGPT Pro:

1. Use ChatGPT web and enable **Settings → Apps → Advanced settings →
   Developer mode**.
2. Open **Settings → Apps → Create**, name the app `yourown-chat`, enter the
   Portal URL, and select OAuth.
3. Select **Scan Tools**, complete the Cloudflare Access login, wait for the
   tool scan, then select **Create**.
4. Start a new chat, enable the draft app from the tools menu, and test a
   read-only Terraform or Google Cloud request.

ChatGPT custom MCP apps are web-only. A Pro account can use read/fetch
capabilities; write/modify actions require Business or Enterprise/Edu. Do not
add the two direct upstream URLs as separate apps unless diagnosing the
Portal—the Portal is the stable client interface.

### Automated rollout verification

The `mcp` pipeline first creates temporary `dev-mcp-*` instances in `dev`.
Kubernetes startup/readiness/liveness probes gate this stage; it does not use
production credentials as a release test. Ready dev instances stay available
for review. Production approval starts an external Cloud Deploy predeploy hook
that scales them to zero, then the prod target deploys and performs credential
verification. Its
Skaffold custom-action container runs in Cloud Build under a dedicated Google
service account, so it creates no pod in GKE. Each verifier Job runs in
`mcp-tunnel`, follows the same NetworkPolicy path as cloudflared, and checks:

- each server's health endpoint;
- a real read-only `list_deployment_runs` call through the
  guarded Stack adapter;
- a real read-only `list_log_names` Google Cloud API call through Workload
  Identity;
- official Gmail, Calendar, and Drive MCP credentials are deliberately not
  impersonated by CI; each Mattermost user verifies the remote connection
  after their own OAuth consent.

Any failure marks verification and the rollout unsuccessful. Apply the
`app-gcp` stack before cutting the first MCP release.

### Manual smoke test

Port-forward each private Service:

```bash
kubectl port-forward -n mcp-terraform-stacks svc/mcp-terraform-stacks 18082:3000
curl -i http://127.0.0.1:18082/health

kubectl port-forward -n mcp-google-cloud svc/mcp-google-cloud 18081:8080
curl -i http://127.0.0.1:18081/healthz

```

Then validate the external path:

0. In Mattermost connect Gmail, Calendar, and Drive, then run one read-only
   request against each service.
1. Confirm that the unauthenticated Portal returns `401` with
   `WWW-Authenticate` and OAuth discovery returns JSON. A direct MCP hostname
   without the Terraform-managed service-token headers is expected to be
   rejected by Access (commonly with a browser-login redirect):

   ```bash
   curl -i https://tools.yourown.chat/mcp
   curl -sS \
     https://tools.yourown.chat/.well-known/oauth-authorization-server
   curl -i https://mcp-google-cloud.yourown.chat/mcp/
   ```

2. Confirm all AI Controls server entries are `Ready`, then add the Portal URL
   to Claude and ChatGPT using **Connect personal clients** above.
3. In each client, verify that Terraform, Terraform Stacks, and Google Cloud
   tools are listed and run one read-only request against each.

## Adding an in-cluster server

1. Add an entry under `servers:` in `helm/mcp/values.yaml` (image,
   port, env, `health`). Transport must be HTTP (streamable-http/SSE); wrap
   stdio-only servers with a gateway image first.
2. Credentials: add a Secret Manager container in app-gcp, grant only the new
   server's Workload Identity `secretAccessor`, and declare its files under
   `servers.<name>.secretProvider.files`. Read the mounted files through
   `<ENV>_FILE`; do not create or synchronize a Kubernetes Secret.
3. Ship: merge → the tag-triggered release renders the profile; the server
   lands with the next prod rollout.

Do not add the new Service FQDN to Mattermost. Register it in Cloudflare AI
Controls and expose it through the existing Portal. Mattermost has no direct
cross-namespace path to MCP Services.
