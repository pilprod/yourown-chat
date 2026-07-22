# MCP integrations

The platform consumes MCP (Model Context Protocol) servers in two ways:

1. **In-cluster (self-hosted)** — deployed by the `mcp-servers` Helm chart
   (`helm/mcp-servers`), rendered onto the prod stage by Cloud Deploy when the
   app-gcp stack sets `mcp_servers_enabled = true`. Each server is an entry in
   `helm/mcp-servers/values.yaml` (`servers.<name>.enabled`) and is reachable
   only from the `mattermost` namespace at
   `http://mcp-<name>.mattermost.svc.cluster.local:<port>/mcp`.
   Credentials, when needed, follow the platform's secret path: Secret Manager
   container (Terraform) → Kubernetes Secret created directly in etcd
   (`cluster_secrets`) → `secretEnvFrom` in the server's values entry. No
   secret ever passes through Cloud Deploy.

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
| Terraform (Registry + **HCP Terraform**) | `hashicorp/terraform-mcp-server` (official) — registry docs tokenless; workspaces/runs/stacks on app.terraform.io once `TFE_TOKEN` is loaded | HCP team token in Secret Manager (`mcp-terraform-hcp-token`, placeholder seeded) |
| Google Cloud (Logging, Monitoring, Trace) | `@krzko/google-cloud-mcp` (community) via supergateway | **none — keyless**: Workload Identity (`mcp-servers` KSA → `mcp` GSA, viewer roles) |
| Google Workspace (Gmail, Calendar) | `google_workspace_mcp` (community, native streamable-http) | OAuth client in Secret Manager + one-time user consent (below) |

#### HCP Terraform token

Create a **team token** in HCP Terraform scoped to the `yourown-chat` project
(least privilege — the token is a shared identity for every chat user of this
server), then:

```bash
printf '%s' "<team-token>" | gcloud secrets versions add mcp-terraform-hcp-token --data-file=-
# re-apply app-gcp, then: kubectl -n mattermost rollout restart deploy/mcp-terraform
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
   kubectl -n mattermost rollout restart deploy/mcp-google-workspace
   ```

3. Users click **Connect** on the server in Agents — that's it. (Mobile apps
   can't start the OAuth flow yet; connect once from web/desktop.)

Plumbing behind it: the server's OAuth endpoints are published at
`https://mcp-google-workspace.yourown.chat` (proxied Cloudflare subdomain → the same
ingress-nginx; the wildcard Origin CA cert covers it; the cloudflare stack owns
the DNS record). The MCP endpoint itself stays OAuth-protected — an
unauthenticated request gets 401, which is exactly what triggers the Connect
flow.

Image pins: both new servers currently ride upstream rolling tags (`latest`)
— pin to a digest after the first successful rollout.

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
| WhatsApp Business | community MCP over WhatsApp Cloud API | Meta Business token | official API — viable |
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

## Zero Trust: private services for people, not the public (flagged off)

The internal MCP servers (terraform, google-cloud) have no auth of their own,
and dev Mattermost is deliberately unreachable from outside the cluster. The
Zero Trust layer moves the perimeter to the Cloudflare edge so authorised
people reach them without making anything public — and without deploying a
tailscale operator for dev access:

```
Claude (custom connector) → MCP Server Portal (beta, dashboard) ┐
Browser → https://dev-mattermost.yourown.chat (no beta involved) ┤
  → Access policy (allowed emails, Google SSO / one-time PIN)    ┘
  → Cloudflare Tunnel (outbound-only cloudflared pod, mattermost ns)
  → mcp-terraform / mcp-google-cloud / dev-mattermost ClusterIP
```

Everything fits the Zero Trust **Free** plan: 50 seats (only Zero Trust users
consume one; Mattermost chat users go in-cluster and consume none), tunnel and
Access apps are free.

The dev Mattermost path is plain browser Access — the mature, non-beta part of
Cloudflare: open the URL, pass the email allow-list, use dev. Only the
cloudflared pod is admitted into the dev namespace (allow-zero-trust-tunnel
NetworkPolicy: pod-exact, port 8065), so this opens nothing else. It works
regardless of how the MCP-portal smoke test below turns out.

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
   Policies:Edit` (keep the existing zone permissions), update the varset —
   BEFORE applying, or the cloudflare apply fails on authorization.
2. Apply **cloudflare**: tunnel (+ token in Secret Manager
   `mcp-tunnel-token`), DNS, Access apps for `mcp-terraform.yourown.chat` /
   `mcp-google-cloud.yourown.chat` / `dev-mattermost.yourown.chat`.
3. Apply **app-gcp**: materialises the in-cluster `mcp-tunnel` Secret. (A run
   racing ahead of step 2 fails on the missing secret — just re-run.)
4. Release: the cloudflared pod connects outbound; hostnames go live behind
   Access. Until step 3 lands the pod waits in CreateContainerConfigError and
   recovers on its own.
5. Zero Trust dashboard (beta, no Terraform resource yet): create an **MCP
   Server Portal**, register the two MCP hostnames as upstream servers, attach
   the Access policy. The portal URL is what personal Claude connects to.
   (dev Mattermost needs no portal — plain browser Access.)

### Smoke test (the reason the kill switch exists)

0. Browser check first: `https://dev-mattermost.yourown.chat` → Access login →
   dev Mattermost. No beta involved; validates tunnel + Access end-to-end.
1. Add the portal URL as a custom connector in claude.ai from **web and
   phone**; Claude Code / desktop from macOS as the control group.
2. Expected: OAuth → Access login (allowed email) → tools listed.
3. Claude Code works but claude.ai web/phone fails at OAuth → the known
   interop gap is still open: use Claude Code/desktop and the Mattermost app
   meanwhile and re-test later — both sides are in active beta. The tunnel
   stays useful regardless (dev Mattermost, Claude Code).

## Adding an in-cluster server

1. Add an entry under `servers:` in `helm/mcp-servers/values.yaml` (image,
   port, env, `health`). Transport must be HTTP (streamable-http/SSE); wrap
   stdio-only servers with a gateway image first.
2. Credentials: add a Secret Manager container in the app-gcp `secrets`
   component, materialise it via `cluster_secrets` into the `mattermost`
   namespace, then reference it with `secretEnvFrom`.
3. Ship: merge → the tag-triggered release renders the profile; the server
   lands with the next prod rollout.
