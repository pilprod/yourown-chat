# Cloudflare operations

The `terraform/cloudflare` Stack owns the `yourown.chat` zone, edge security,
Origin CA and Authenticated Origin Pull certificates, Zero Trust Tunnel,
Access applications, AI Controls MCP registrations, the shared MCP Portal, and
its OAuth compatibility Worker + KV namespace. Cloudflare provider 5.22.x is
the supported baseline.

## API token permissions

The account-scoped token stored in the HCP Terraform varset requires:

- Cloudflare Tunnel: Edit
- Access: Apps and Policies: Edit
- Access: Service Tokens: Edit
- Access: Organizations, Identity Providers, and Groups: Edit
- MCP Portals: Edit
- Workers Scripts: Edit
- Workers KV Storage: Edit
- Workers Routes: Edit

Keep the existing zone-scoped DNS, SSL and Certificates, Zone Settings,
Single Redirect, and Zone WAF permissions.

## MCP Portal

Terraform keeps the public client endpoint stable but separates it from the AI
Controls Portal origin:

```text
Claude / Codex / ChatGPT
  -> mcp.yourown.chat (OAuth compatibility Worker)
  -> mcp-origin.yourown.chat (service-token-only AI Controls Portal)
  -> private MCP origins
```

The Worker uses Cloudflare's official `workers-oauth-provider` library for
OAuth 2.1, PKCE, dynamic client registration, MCP resource binding, and token
storage. Access for SaaS performs the interactive Cloudflare Access login. The
Portal's `type = "mcp_portal"` application has Managed OAuth disabled and
accepts only the Worker's machine identity.

The client endpoint is:

```text
https://mcp.yourown.chat/mcp
```

### Client authentication and refresh

This repository makes the `yourown-chat` MCP server required in
`.codex/config.toml`. A new Codex task must fail during startup when the Portal
cannot initialize instead of silently continuing without its operational
tools.

Worker access tokens last 15 minutes and refresh grants last two weeks. The
provider keeps the newest two refresh tokens valid, so a retry or concurrent
refresh cannot permanently lose the grant. Reauthorizing the same user/client
also leaves its other active grants intact; this supports Claude web/mobile and
multiple Codex tasks without one session revoking another.

The migration from Portal Managed OAuth changes the authorization server and
invalidates the old Cloudflare-issued credentials once. Reauthorize each
client after the Worker is first deployed:

```bash
codex mcp logout yourown-chat
codex mcp login yourown-chat
```

After the browser flow succeeds, start a new task and confirm that the
`yourown-chat` tools are present. Subsequent 15-minute refreshes must be silent.
Do not use a local MCP client, `kubectl`, or `gcloud` as an operational
fallback.

Worker invocation logs distinguish the relevant phases without recording
tokens:

- `oauth_authorization_completed`: Access login produced an MCP grant;
- `oauth_token_exchange` with `grant_type=refresh_token`: a client refreshed;
- `oauth_error`: the provider rejected a request;
- `portal_proxy`: an authenticated MCP request reached the Portal origin.

For every release, keep one Claude and one Codex connection active past the
first 15-minute boundary and require a successful read-only tool call from
both. An absent `oauth_token_exchange` identifies a client-side refresh defect;
an `oauth_error` identifies a server-side rejection.

### Upstream authentication and initial synchronization

Terraform creates one Cloudflare Access service token for AI Controls, adds a
`Service Auth` policy to each direct MCP Access application, and stores the
token's two headers in each AI Controls server registration. The secret stays
inside encrypted Terraform state and Cloudflare; it is never sent to Claude,
ChatGPT, Mattermost, a phone, or a user laptop.

No interactive authorization is required between the Portal and its registered
upstreams. After apply, AI Controls
uses these headers for both capability synchronization and Portal-to-upstream
requests:

- `CF-Access-Client-Id`
- `CF-Access-Client-Secret`

The Portal mapping keeps `on_behalf = false`. A human authenticates once
through the Worker's Access for SaaS flow and is not prompted separately for
Terraform or Google Cloud. The MCP processes still use their own in-cluster
workload credentials for calls to HCP Terraform and Google Cloud.

Continue only after both AI Controls entries show `Ready` and a non-zero tool
count. `Waiting` means Cloudflare cannot yet initialize the upstream MCP
session: inspect the status error, verify the direct hostname and Access
policy, then select **… → Sync capabilities**. The service token lasts one
year (`8760h`); rotate it before expiry by replacing the resource through
Terraform. The temporary shared token is intentional—split it into one token
and least-privilege policy per MCP server when the role model is implemented.

Capability synchronization uses this AI Controls machine credential. It does
not read, rotate, or revoke the end-user grants stored in the Worker's OAuth KV
namespace, so a postdeploy catalog refresh cannot disconnect Claude or Codex.

## DNSSEC

The registrar transfer completed on 2026-07-25. Cloudflare Registrar now
publishes the DS record in the parent `.chat` zone, and Terraform converges the
zone to `status = "active"` without a migration lifecycle exception. Verify the
delegation with:

```bash
curl -fsSL https://rdap.org/domain/yourown.chat
dig +short DS yourown.chat @1.1.1.1
```

The RDAP response must identify Cloudflare as registrar and the DS query must
return key tag `2371`, algorithm `13`, digest type `2`. Do not reintroduce a
DNSSEC `ignore_changes`: it would hide a future delegation regression.

## Stable Origin CA plans

Provider v5 models Origin CA certificate hostnames as an ordered ForceNew list.
The module sorts the full SAN list and reuses it for both the CSR and the
Cloudflare resource. Keep this normalization and `create_before_destroy`;
otherwise apex/wildcard ordering can cause repeated certificate rotations.
