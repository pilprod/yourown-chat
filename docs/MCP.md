# MCP integrations

The platform consumes MCP (Model Context Protocol) servers in two ways:

1. **In-cluster (self-hosted)** — deployed by the `mcp` Helm chart
   (`helm/mcp`), rendered onto the prod stage by Cloud Deploy when the
   app-gcp stack sets `mcp_servers_enabled = true`. Each server is an entry in
   `helm/mcp/values.yaml` (`servers.<name>.enabled`). Production is reachable
   across namespaces only from `mattermost`, at
   `http://mcp-<name>.mcp-<name>.svc.cluster.local:<port>/mcp`. Every server
   has its own default-deny namespace (`mcp-terraform`,
   `mcp-terraform-stacks`, `mcp-google-cloud`, or
   `mcp-whatsapp-business`), so a compromised server
   cannot initiate traffic to another MCP server. Each server admits only Mattermost and the Cloudflare
   Tunnel connector in the separate `mcp-tunnel` namespace. Egress is limited
   to cluster DNS plus encrypted external API/Tunnel traffic.
   Credentials, when needed, follow the platform's secret path: Secret Manager
   container (Terraform) → Kubernetes Secret created directly in etcd
   (`cluster_secrets`) → `secretEnvFrom` in the server's values entry. No
   secret ever passes through Cloud Deploy. The MCP Secret Manager containers
   use the same regional CMEK (`cmek_key_id`) and least-privilege Workload
   Identity accessor as the production Mattermost database secrets; only the
   resulting Kubernetes Secrets are materialised in etcd.
   Disposable `dev-mcp-*` instances instead share the quota-bound `dev`
   namespace with dev Mattermost and dev Postgres. They use the `development`
   PriorityClass, the tenant's default-deny/intra-namespace policies, duplicate
   namespace-scoped credential Secrets, and a `dev/mcp-servers` KSA bound to
   the same read-only Google Cloud MCP GSA.

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

GKE therefore registers and introspects Terraform, Terraform Stacks, Google
Cloud, and WhatsApp Business MCP after their production rollout. The dev overlay deliberately
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
| Endpoint | Meta Graph API | `https://graph.facebook.com/v23.0` |
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

The four GKE servers should expose discovered tools after introspection. The
manually registered Meta entry is expected to show endpoint metadata without a
Terraform-managed tool specification.

## Integration matrix

Status of every requested integration. "Community" servers are third-party
code: pin images deliberately, review before enabling, and expect API-ToS
constraints (especially for consumer services without a public API).

### Live in-cluster

| Service | Server | Credentials |
|---|---|---|
| Terraform (Registry + **HCP Terraform**) | internally mirrored `hashicorp/terraform-mcp-server@sha256:67b4…` (official) — registry docs tokenless; workspaces/runs/stacks on app.terraform.io once `TFE_TOKEN` is loaded | HCP team token in Secret Manager (`mcp-terraform-hcp-token`, placeholder seeded) |
| Terraform Stacks approvals | internally built `mcp-terraform-stacks` adapter over the official HCP Terraform Stacks API; plan inspection plus guarded run-scoped approve/cancel | same HCP team token, with Project Write or higher |
| Google Cloud (Logging, Monitoring, Trace, Error Reporting) | internally built `mcp-google-cloud` image: `@google-cloud/observability-mcp@0.2.3` (Google, preview) + `supergateway@3.4.3` | **none — keyless**: Workload Identity (`mcp-google-cloud/mcp-servers` in prod and `dev/mcp-servers` in dev → `mcp` GSA, viewer roles); quota project is `yourown-chat` |
| WhatsApp Business | internally built adapter over the official Meta WhatsApp Cloud API | Meta system-user token, WABA ID and phone-number ID in Secret Manager |

The Google Cloud server is published as an npm/stdio package, not a container
with native HTTP transport. The platform therefore builds
`docker/mcp/google-cloud/Dockerfile` itself. Its committed
`package-lock.json` pins the complete dependency graph; the image contains the
official package and starts supergateway in stateful Streamable HTTP mode.
There is no package download, writable npm cache, or init container at runtime.

When `docker/mcp/google-cloud/**` or the shared `docker/base/**` changes, the
unified release trigger
audits, builds, and pushes
`europe-west3-docker.pkg.dev/yourown-chat/docker/mcp-google-cloud:<git-sha>`
before it creates an MCP release. Other MCP-only changes reuse the newest
internal image rather than rebuilding identical dependencies. The trigger
resolves the selected digest and passes
`mcp_google_cloud_image=<repository>@sha256:...` to Cloud Deploy, so both dev
and prod promote the exact same artifact. Automatic Artifact Analysis scanning
is enabled for the repository by `platform-gcp`.

Inspect the deployed digest and its current package findings:

```bash
IMAGE_ID="$(kubectl -n mcp-google-cloud get pod \
  -l app=mcp-google-cloud \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
printf '%s\n' "$IMAGE_ID"

gcloud artifacts docker images describe \
  "${IMAGE_ID#docker-pullable://}" \
  --show-package-vulnerability
```

Artifact Analysis updates findings for an existing digest as its vulnerability
database changes. A rebuild is required only to consume fixed base packages or
an updated npm lock.

`docker/base/Dockerfile` produces the internally scanned
`base` image from a pinned Debian digest.
`docker/base/node.Dockerfile` and `docker/base/python.Dockerfile` create the
language runtimes on top; application Dockerfiles consume only
`RUNTIME_IMAGE`. This centralises CA certificates, the non-root UID, OS
packages, and runtime policy without adding Node to the Python image.

`docker/images.tsv` is the single image catalog for built and mirrored images.
Both the tag-triggered and manual Cloud Build paths call
`docker/prepare-images.sh`, `docker/audit-images.sh`, and
`docker/build-images.sh`; they do not maintain per-image checkout or build
snippets. External Git contexts and their pinned revisions, plus OCI title,
source, description, revision and version labels, all come from the catalog.
Parent changes propagate through the catalog, missing
`runtime` tags bootstrap automatically, and every published image also gets an
immutable build tag. Mattermost remains on its upstream image, while the
official Terraform and cloudflared images are catalogued as byte-for-byte
mirrors rather than rebased.

For a local build, build the base once and pass it explicitly:

```bash
docker build -t base:local docker/base
docker build -f docker/base/node.Dockerfile \
  --build-arg BASE_IMAGE=base:local \
  -t node:local docker/base
docker build --build-arg RUNTIME_IMAGE=node:local \
  -t mcp-whatsapp-business:local docker/mcp/whatsapp-business
```

`docker/mcp/upstreams.env` is the reviewable upstream lock for the other
runtime images. Terraform MCP 0.5.2 and cloudflared 2026.7.3 are pulled by their
official multi-architecture digest and mirrored into the internal repository.
WhatsApp Business is built from the committed Node.js source and lock file in
`docker/mcp/whatsapp-business`. Every in-cluster workload is rendered with an
Artifact Registry `@sha256` reference.

#### HCP Terraform token

Create a **team token** in HCP Terraform scoped to the `yourown-chat` project
(least privilege — the token is a shared identity for every chat user of this
server), then:

```bash
printf '%s' "<team-token>" | gcloud secrets versions add mcp-terraform-hcp-token --data-file=-
# Re-apply app-gcp, then restart both consumers:
kubectl -n mcp-terraform rollout restart deploy/mcp-terraform
kubectl -n mcp-terraform-stacks rollout restart deploy/mcp-terraform-stacks
```

The server reads the target address only from its own `TFE_ADDRESS` env
(`https://app.terraform.io`); attempts to override it per-request are rejected,
so chat input cannot repoint the server at another Terraform instance.

The approval adapter resolves Stack IDs inside organization `papou-work` from
the committed name allowlist:

- `cloudflare`;
- `app-gcp`;
- `platform-gcp`;
- `agent-registry-gcp`.

`agent-registry-gcp` may be absent until that HCP Stack is created or the
existing catalog Stack is renamed; it becomes available automatically once its
name matches. Approval requires the exact `sdr-*` run ID, the exact `stc-*`
configuration ID returned by the inspection tool, a reason, and the literal
confirmation `APPROVE`. The adapter verifies that the run belongs to the named
allowlisted Stack and has a plan step in `pending_operator`, then calls the
run-scoped endpoint with `all_plans=false`. It never exposes deployment-group
approval or approval of later plans.

Rollout order for the Google Cloud server: apply **platform-gcp first** (creates
the `mcp` GSA + Workload Identity binding and publishes it in
`workload_identity_emails`), then app-gcp (injects the GSA into the KSA
annotation via the `mcp_gsa` deploy parameter), then a release.

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

The OAuth client ID and secret are entered in Mattermost's MCP server settings,
not placed in Kubernetes. Mattermost stores a separate OAuth token for every
user, so each user must click **Connect** and grant their own Google access.
Use the smallest scopes required by the enabled tools and require confirmation
for tools that send mail, change calendars, or create/copy Drive files.

#### Meta Developer Tools and business messaging

Meta now publishes the official, beta **Meta Developer Tools MCP** at
`https://mcp.facebook.com/devtools`. It covers developer-platform operations:
app configuration and diagnostics, API health, App Review/compliance,
documentation/changelog search, and webhook subscription administration. It
does **not** send or receive WhatsApp, Messenger, or Instagram messages.

The repository therefore still owns a small Streamable HTTP WhatsApp adapter
in `docker/mcp/whatsapp-business/server.mjs`, which calls only the official
WhatsApp Cloud API. It does not use WhatsApp Web, a QR session, Baileys, or
another personal-account bridge.

The server exposes tools to send text, template, and link-hosted media
messages; mark a message as read; and inspect the business profile, phone
number, and message templates.

**Where to get the three keys** (all from [Meta Business Suite / Developers](https://developers.facebook.com)):

1. **One-time setup.** In [business.facebook.com](https://business.facebook.com)
   confirm you have a **WhatsApp Business Account (WABA)** and a phone number
   (Business Settings → Accounts → WhatsApp Accounts). In
   [developers.facebook.com](https://developers.facebook.com) create/open a
   **Business-type app** and add the **WhatsApp** product to it.

2. **`mcp-whatsapp-waba-id`** — the WABA ID. App dashboard → **WhatsApp → API
   Setup**: the "WhatsApp Business Account ID" shown there (also in Business
   Settings → WhatsApp Accounts → your account).

3. **`mcp-whatsapp-phone-number-id`** — the sender's **Phone number ID** (NOT
   the phone number itself). Same **WhatsApp → API Setup** page, under "From",
   next to the number — a numeric ID.

4. **`mcp-whatsapp-access-token`** — a **permanent System-User token** (the
   24-hour test token expires, don't use it). Business Settings → **Users →
   System users** → add/select a system user → **Generate new token** → pick
   your app → grant **`whatsapp_business_messaging`** and
   **`whatsapp_business_management`** → set expiry **Never**. Also assign the
   WABA to that system user (System users → Assign assets → your WABA → full
   control) or the token can't act on it.

Then replace the seeded Secret Manager placeholders:

```bash
printf '%s' "<system-user-token>" | gcloud secrets versions add mcp-whatsapp-access-token --data-file=-
printf '%s' "<waba-id>"           | gcloud secrets versions add mcp-whatsapp-waba-id --data-file=-
printf '%s' "<phone-number-id>"   | gcloud secrets versions add mcp-whatsapp-phone-number-id --data-file=-
```

Re-apply `terraform/app-gcp`, then restart
`deployment/mcp-whatsapp-business` in namespace `mcp-whatsapp-business`.
In Mattermost add it as `WhatsApp Business` with URL
`http://mcp-whatsapp-business.mcp-whatsapp-business.svc.cluster.local:3000/mcp`;
leave headers and OAuth credentials empty because Meta credentials stay on the
server.
The initial integration is outbound/admin only and needs no public webhook.
Receiving messages later should use a separate public webhook path which
validates Meta's signature; do not publish the MCP endpoint itself.

For Facebook Messenger and Instagram messaging, reuse the official Meta Graph
APIs rather than treating Developer Tools MCP as a messaging gateway. The
recommended evolution is one reviewed `mcp-meta` codebase/image with shared
Graph API transport, validation, retries, and webhook verification, but three
least-privilege runtime boundaries:

| Runtime | Identity/configuration | Purpose |
|---|---|---|
| `mcp-meta-whatsapp` | system-user token, WABA ID, phone-number ID | WhatsApp Cloud API |
| `mcp-meta-messenger` | Page access token and Messenger-approved permissions | Facebook Page Messenger |
| `mcp-meta-instagram` | Instagram professional-account token and approved messaging permissions | Instagram Direct |

Keep separate Helm releases, namespaces, Secrets, and Agent Registry entries
even if they share one image. This avoids turning one leaked token or one
compromised runtime into access to all Meta surfaces. A Meta Business app can
host the required products, but product access, App Review, tokens, webhook
topics, and user/account eligibility remain product-specific. Build Messenger
and Instagram adapters only when their exact tool set and inbound webhook
contract are defined; the current WhatsApp deployment should not be deleted
before that replacement exists.

## Connect Terraform, Google Cloud, and Google Workspace to Mattermost

Open **System Console → Plugins → Agents → MCP Servers** (the label can be
**Remote MCP Servers** in some plugin versions), add the server, save, then
enable it for the required agent.

For Terraform use:

- Name: `Terraform`
- Enabled: `true`
- Server URL:
  `http://mcp-terraform.mcp-terraform.svc.cluster.local:8080/mcp`
- Headers: empty
- OAuth credentials: empty

The HCP Terraform team token is already injected into the server from its
Kubernetes Secret; never paste it into Mattermost. After saving, enable the
Terraform tools for the agent and test with a read-only request such as listing
the accessible HCP Terraform workspaces.

For Google Cloud use:

- Name: `Google Cloud`
- Enabled: `true`
- Server URL:
  `http://mcp-google-cloud.mcp-google-cloud.svc.cluster.local:8080/mcp`
- Headers: empty
- OAuth credentials: empty

The pod authenticates through GKE Workload Identity. Mattermost must not use
the public Cloudflare URL or receive a Google service-account key. After
saving, enable the tools for the agent and test with a read-only request such
as listing Cloud Logging log names.

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
| WhatsApp personal | community bridges (whatsmeow) | phone session | unofficial protocol use — account-ban risk, not recommended |
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

Everything fits the Zero Trust **Free** plan: 50 seats (only Zero Trust users
consume one; Mattermost chat users go in-cluster and consume none), tunnel and
Access apps are free. Cloudflare OAuth tokens do not consume LLM/API tokens;
the limits and subscription of the MCP client itself are separate.

The layer ships **enabled** (`zero_trust_enabled = true` in both stacks,
`tunnel.enabled: true` in the chart, allowed emails committed); the account ID
is derived from the zone lookup. The flags are the kill switch for the
external private-service path. Mattermost continues to use in-cluster Service
URLs and does not traverse Cloudflare.

### Human clients use Portal OAuth; Cloudflare uses a service token upstream

Claude and ChatGPT connect only to the MCP Portal. Terraform enables Managed
OAuth and dynamic client registration on the Portal's `type = "mcp_portal"`
Access application. It permits loopback callbacks plus the hosted Claude,
ChatGPT, Cloudflare Playground, and shared Cloudflare callback URIs. Access
tokens last 15 minutes and grants last two weeks.

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
Terraform MCP still uses its configured HCP credential.

The Cloudflare stack uses provider 5.22.x, registers every configured server in AI
Controls, and creates a single `https://mcp.yourown.chat/mcp` MCP Portal. This
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
2. Apply **cloudflare**: tunnel (+ token in Secret Manager
   `mcp-tunnel-token`), DNS, Access apps for `dev.yourown.chat` /
   every configured MCP hostname, including
   `mcp-terraform-stacks.yourown.chat`.
3. Apply **platform-gcp**, then **app-gcp**: the former binds Workload Identity
   to both `mcp-google-cloud/mcp-servers` and `dev/mcp-servers`; the latter
   creates one namespace per production MCP server plus `mcp-tunnel`, and
   materialises credentials in both each production namespace and `dev`
   before Cloud Deploy runs. (A release racing ahead of this step fails on a
   missing Secret — apply and re-run the release.)
4. Release: the cloudflared pod connects outbound; hostnames go live behind
   Access. Until step 3 lands the pod waits in CreateContainerConfigError and
   recovers on its own.
5. Terraform supplies the Access service-token headers to all AI Controls
   registrations. No upstream browser authorization is required. If a server
   remains `Waiting`, inspect its error and run **Sync capabilities** as
   documented in [`CLOUDFLARE.md`](CLOUDFLARE.md). Do not configure a client
   until all servers show `Ready`.

### Connect personal clients

Use the single Portal endpoint in every remote client:

```text
https://mcp.yourown.chat/mcp
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
- a real read-only `list_terraform_orgs` HCP Terraform API call;
- a real read-only `terraform_stacks_list_deployment_runs` call through the
  guarded Stack adapter;
- a real read-only `list_log_names` Google Cloud API call through Workload
  Identity;
- a real read-only `whatsapp_get_phone_number` Meta API call;
- official Gmail, Calendar, and Drive MCP credentials are deliberately not
  impersonated by CI; each Mattermost user verifies the remote connection
  after their own OAuth consent.

Any failure marks verification and the rollout unsuccessful. Apply the
`app-gcp` stack before cutting the first MCP release.

### Manual smoke test

Port-forward each private Service:

```bash
kubectl port-forward -n mcp-terraform svc/mcp-terraform 18080:8080
curl -i http://127.0.0.1:18080/health

kubectl port-forward -n mcp-terraform-stacks svc/mcp-terraform-stacks 18082:3000
curl -i http://127.0.0.1:18082/health

kubectl port-forward -n mcp-google-cloud svc/mcp-google-cloud 18081:8080
curl -i http://127.0.0.1:18081/healthz

kubectl port-forward -n mcp-whatsapp-business svc/mcp-whatsapp-business 18083:3000
curl -i http://127.0.0.1:18083/health
```

Then validate the external path:

0. In Mattermost connect Gmail, Calendar, and Drive, then run one read-only
   request against each service.
1. Confirm that the unauthenticated Portal returns `401` with
   `WWW-Authenticate` and OAuth discovery returns JSON. A direct MCP hostname
   without the Terraform-managed service-token headers is expected to be
   rejected by Access (commonly with a browser-login redirect):

   ```bash
   curl -i https://mcp.yourown.chat/mcp
   curl -sS \
     https://mcp.yourown.chat/.well-known/oauth-authorization-server
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
2. Credentials: add a Secret Manager container in the app-gcp `secrets`
   component, materialise it via `cluster_secrets` into that server's dedicated
   `mcp-<server>` namespace, then reference it with `secretEnvFrom`.
3. Ship: merge → the tag-triggered release renders the profile; the server
   lands with the next prod rollout.

Also add the new Service FQDN to
`MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS` in both Mattermost
environment templates. Mattermost deliberately blocks user-controlled
integration requests to reserved IP ranges; this repository allowlists exact
MCP Service names rather than a broad Pod or Service CIDR.
