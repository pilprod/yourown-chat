# MCP integrations

The platform consumes MCP (Model Context Protocol) servers in two ways:

1. **In-cluster (self-hosted)** — deployed by the `mcp` Helm chart
   (`helm/mcp`), rendered onto the prod stage by Cloud Deploy when the
   app-gcp stack sets `mcp_servers_enabled = true`. Each server is an entry in
   `helm/mcp/values.yaml` (`servers.<name>.enabled`) and is reachable
   across namespaces only from `mattermost`, at
   `http://mcp-<name>.mcp-<name>.svc.cluster.local:<port>/mcp`. Every server
   has its own default-deny namespace (`mcp-terraform`, `mcp-google-cloud`,
   `mcp-google-workspace`, or `mcp-whatsapp-business`), so a compromised server
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

2. **Vendor-hosted (remote)** — the vendor runs the MCP endpoint; agents
   connect to its URL with OAuth. Nothing to deploy or operate on our side.
   Preferred whenever an official remote endpoint exists.

## Integration matrix

Status of every requested integration. "Community" servers are third-party
code: pin images deliberately, review before enabling, and expect API-ToS
constraints (especially for consumer services without a public API).

### Live in-cluster

| Service | Server | Credentials |
|---|---|---|
| Terraform (Registry + **HCP Terraform**) | internally mirrored `hashicorp/terraform-mcp-server@sha256:67b4…` (official) — registry docs tokenless; workspaces/runs/stacks on app.terraform.io once `TFE_TOKEN` is loaded | HCP team token in Secret Manager (`mcp-terraform-hcp-token`, placeholder seeded) |
| Google Cloud (Logging, Monitoring, Trace, Error Reporting) | internally built `mcp-google-cloud` image: `@google-cloud/observability-mcp@0.2.3` (Google, preview) + `supergateway@3.4.3` | **none — keyless**: Workload Identity (`mcp-google-cloud/mcp-servers` KSA → `mcp` GSA, viewer roles); quota project is `yourown-chat` |
| Google Workspace (Gmail, Calendar) | internally built `google_workspace_mcp` v1.22.1 at commit `da3c708…` (community, native streamable-http) | OAuth client in Secret Manager + one-time user consent (below) |
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
`europe-west3-docker.pkg.dev/yourown-chat/docker/mcp/google-cloud:<git-sha>`
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
`yourown-chat/base` image from a pinned Debian digest.
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
docker build -t yourown-chat/base:local docker/base
docker build -f docker/base/node.Dockerfile \
  --build-arg BASE_IMAGE=yourown-chat/base:local \
  -t yourown-chat/node:local docker/base
docker build --build-arg RUNTIME_IMAGE=yourown-chat/node:local \
  -t mcp/whatsapp-business:local docker/mcp/whatsapp-business
```

`docker/mcp/upstreams.env` is the reviewable upstream lock for the other
runtime images. Terraform MCP 0.5.2 and cloudflared 2026.7.3 are pulled by their
official multi-architecture digest and mirrored into the internal repository.
Google Workspace is built from its exact release commit with our pinned Python
base image and `uv` version; its upstream `uv.lock` remains authoritative for
Python dependencies. Changing the lock file or internal Workspace Dockerfile
builds new internal images. WhatsApp Business is built from the committed
Node.js source and lock file in `docker/mcp/whatsapp-business`. All five
workloads are rendered with Artifact Registry `@sha256` references.

#### HCP Terraform token

Create a **team token** in HCP Terraform scoped to the `yourown-chat` project
(least privilege — the token is a shared identity for every chat user of this
server), then:

```bash
printf '%s' "<team-token>" | gcloud secrets versions add mcp-terraform-hcp-token --data-file=-
# re-apply app-gcp, then: kubectl -n mcp-terraform rollout restart deploy/mcp-terraform
```

The server reads the target address only from its own `TFE_ADDRESS` env
(`https://app.terraform.io`); attempts to override it per-request are rejected,
so chat input cannot repoint the server at another Terraform instance.

Rollout order for the Google Cloud server: apply **platform-gcp first** (creates
the `mcp` GSA + Workload Identity binding and publishes it in
`workload_identity_emails`), then app-gcp (injects the GSA into the KSA
annotation via the `mcp_gsa` deploy parameter), then a release.

#### Google Workspace: per-user OAuth (no manual consent plumbing)

The server runs in OAuth 2.1 **multi-user** mode: Mattermost Agents shows each
user a **Connect** button, the user passes the Google consent under their own
account in the browser, and every tool call then runs with that user's token —
each user sees only their own Gmail/Calendar. Operator setup is one-time:

1. In Google Cloud console create an **OAuth client ID** (type: Web
   application, redirect URI
   `https://mcp-google-workspace.yourown.chat/oauth2callback`) under a project with
   the Gmail and Calendar APIs enabled.
2. Load the real values over the seeded placeholders:

   ```bash
   printf '%s' "<client-id>"     | gcloud secrets versions add mcp-google-workspace-client-id --data-file=-
   printf '%s' "<client-secret>" | gcloud secrets versions add mcp-google-workspace-client-secret --data-file=-
   # re-apply app-gcp (cluster_secrets picks up the new versions), then:
   kubectl -n mcp-google-workspace rollout restart deploy/mcp-google-workspace
   ```

3. Users click **Connect** on the server in Agents — that's it. (Mobile apps
   can't start the OAuth flow yet; connect once from web/desktop.)

Plumbing behind it: the server's OAuth endpoints are published at
`https://mcp-google-workspace.yourown.chat` (Cloudflare Access → Tunnel → private
ClusterIP; the cloudflare stack owns the DNS record). The MCP endpoint itself stays OAuth-protected — an
unauthenticated request gets 401, which is exactly what triggers the Connect
flow.

#### WhatsApp Business Cloud API

Meta does not publish an official MCP server. This repository therefore owns a
small Streamable HTTP adapter in `docker/mcp/whatsapp-business/server.mjs`
which calls only the official WhatsApp Cloud API. It does not use WhatsApp Web,
a QR session, Baileys, or another personal-account bridge.

The server exposes tools to send text, template, and link-hosted media
messages; mark a message as read; and inspect the business profile, phone
number, and message templates. Create a Meta Business app with the WhatsApp
product, a WABA and phone number, then issue a permanent system-user token with
`whatsapp_business_messaging` and `whatsapp_business_management`. Replace the
seeded Secret Manager placeholders:

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

## Connect Terraform and Google Workspace to Mattermost

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

For Google Workspace use:

- Name: `Google Workspace`
- Enabled: `true`
- Server URL:
  `http://mcp-google-workspace.mcp-google-workspace.svc.cluster.local:8000/mcp`
- Headers: empty
- OAuth credentials: empty

Save it, enable its tools for the agent, and click **Connect** in Mattermost
web or desktop. Complete Cloudflare Access if requested, then Google consent.
The OAuth client is configured on the MCP server and each Mattermost user gets
their own Google token, so client ID and secret must not be copied into
Mattermost. If **Connect** is absent, first verify that
`https://mcp-google-workspace.yourown.chat` is reachable through Access and
that its OAuth redirect URI is registered exactly as documented above.

### Official vendor-hosted remote — connect, nothing to deploy

| Service | Remote endpoint | Auth |
|---|---|---|
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
Access apps are free.

For a browser-based client, open the protected hostname and complete the
Access login. No Cloudflare WARP client is required on macOS or iOS: the
browser holds the Access session. Native/non-browser MCP clients must support
the Access browser/OAuth flow or use an explicitly provisioned machine/service
credential; WARP is optional and is not part of this Tunnel route.

The layer ships **enabled** (`zero_trust_enabled = true` in both stacks,
`tunnel.enabled: true` in the chart, allowed emails committed); the account ID
is derived from the zone lookup. The flags are the **kill switch**: the
claude.ai web/mobile connector has a KNOWN OAuth interop issue against
Access-fronted MCP portals (Claude Code works against the same URL) — if the
smoke test below fails, that path simply stays unused (or flip the flags off);
nothing else depends on it.

### Rollout (in order)

1. **Prerequisite Terraform cannot do**: re-issue the Cloudflare API token
   with ACCOUNT permissions `Cloudflare Tunnel:Edit` + `Access: Apps and
   Policies:Edit` + `Access: Organizations, Identity Providers, and
   Groups:Edit` (keep the existing zone permissions), update the varset —
   BEFORE applying, or the cloudflare apply fails on authorization. The stack
   adopts the existing Zero Trust organization and renames its team/domain to
   `yourown-chat` / `yourown-chat.cloudflareaccess.com`; clients using the old
   `yellow-sunset-672e.cloudflareaccess.com` domain must be updated.
2. Apply **cloudflare**: tunnel (+ token in Secret Manager
   `mcp-tunnel-token`), DNS, Access apps for `dev.yourown.chat` /
   `mcp-terraform.yourown.chat` / `mcp-google-cloud.yourown.chat` /
   `mcp-google-workspace.yourown.chat`.
3. Apply **platform-gcp**, then **app-gcp**: the former binds Workload Identity
   to `mcp-google-cloud/mcp-servers`; the latter creates one namespace per MCP
   server plus `mcp-tunnel`, and materialises every Secret in its consuming
   namespace before Cloud Deploy runs. (A release racing ahead of this step
   fails on a missing Secret — apply and re-run the release.)
4. Release: the cloudflared pod connects outbound; hostnames go live behind
   Access. Until step 3 lands the pod waits in CreateContainerConfigError and
   recovers on its own.
5. Zero Trust dashboard (beta, no Terraform resource yet): create an **MCP
   Server Portal**, register the two MCP hostnames as upstream servers, attach
   the Access policy. The portal URL is what personal Claude connects to.
   The portal URL is the address used by compatible personal MCP clients.

### Automated rollout verification

The `mcp` pipeline first creates temporary `dev-mcp-*` instances and runs the
dev protocol verifier. Successful dev instances stay available for review.
Production approval starts an external Cloud Deploy predeploy hook that scales
them to zero, then the prod target deploys and repeats verification. Its
Skaffold custom-action container runs in Cloud Build under a dedicated Google
service account, so it creates no pod in GKE. Each verifier Job runs in
`mcp-tunnel`, follows the same NetworkPolicy path as cloudflared, and checks:

- each server's health endpoint;
- an MCP `initialize` exchange with Terraform, Google Cloud, and WhatsApp
  Business;
- the expected unauthenticated `401` from Google Workspace in OAuth 2.1 mode.

Any failure marks verification and the rollout unsuccessful. Apply the
`app-gcp` stack before cutting the first MCP release.

### Manual smoke test

Port-forward each private Service:

```bash
kubectl port-forward -n mcp-terraform svc/mcp-terraform 18080:8080
curl -i http://127.0.0.1:18080/health

kubectl port-forward -n mcp-google-cloud svc/mcp-google-cloud 18081:8080
curl -i http://127.0.0.1:18081/healthz

kubectl port-forward -n mcp-google-workspace svc/mcp-google-workspace 18082:8000
curl -i http://127.0.0.1:18082/health

kubectl port-forward -n mcp-whatsapp-business svc/mcp-whatsapp-business 18083:3000
curl -i http://127.0.0.1:18083/health
```

Then validate the external path:

0. Browser check first: `https://mcp-google-workspace.yourown.chat` → Access
   login → Google OAuth Connect flow. This validates Tunnel + Access end-to-end.
1. Add the portal URL as a custom connector in claude.ai from **web and
   phone**; Claude Code / desktop from macOS as the control group.
2. Expected: OAuth → Access login (allowed email) → tools listed.
3. Claude Code works but claude.ai web/phone fails at OAuth → the known
   interop gap is still open: use Claude Code/desktop meanwhile and re-test
   later — both sides are in active beta.

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
