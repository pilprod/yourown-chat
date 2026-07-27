# Cloudflare operations

The `terraform/cloudflare` Stack owns the `yourown.chat` zone, edge security,
Origin CA and Authenticated Origin Pull certificates, Zero Trust Tunnel,
Access applications, AI Controls MCP registrations, and the shared MCP Portal.
Cloudflare provider 5.22.x is the supported baseline.

## API token permissions

The account-scoped token stored in the HCP Terraform varset requires:

- Cloudflare Tunnel: Edit
- Access: Apps and Policies: Edit
- Access: Service Tokens: Edit
- Access: Organizations, Identity Providers, and Groups: Edit
- MCP Portals: Edit

Keep the existing zone-scoped DNS, SSL and Certificates, Zone Settings,
Single Redirect, and Zone WAF permissions.

## MCP Portal

Terraform explicitly manages the AI Controls Portal and its separate
`type = "mcp_portal"` Access application. The application owns the email allow
policy, Managed OAuth, dynamic client registration, and token lifetimes.

The client endpoint is:

```text
https://tools.yourown.chat/mcp
```

`tools` is the stable tool-gateway name. The `/mcp` protocol path is fixed by
Cloudflare. Keep `agents.yourown.chat` unallocated for the future
Mattermost/Temporal agent control plane.

### Codex client authentication

This repository makes the `yourown-chat` MCP server required in
`.codex/config.toml`. A new Codex task must fail during startup when the Portal
cannot initialize instead of silently continuing without its operational
tools.

Managed OAuth access tokens last 15 minutes. The Portal Access session and its
refresh grant both last two weeks (`336h`); keep these values identical so an
otherwise-valid refresh grant is not invalidated by an earlier Access-session
expiry. Claude, Codex, and other clients should rotate their access tokens
automatically throughout that period.

When the full two-week grant expires, its refresh token is revoked, or the user
selects **Sign out** on the Portal homepage, reauthorize the client explicitly:

```bash
codex mcp logout yourown-chat
codex mcp login yourown-chat
```

After the browser flow succeeds, start a new task and confirm that the
`yourown-chat` tools are present. Do not use a local MCP client, `kubectl`, or
`gcloud` as an operational fallback.

### Upstream authentication and initial synchronization

Terraform creates one Cloudflare Access service token for AI Controls, adds a
`Service Auth` policy to each direct MCP Access application, and stores the
token's two headers in each AI Controls server registration. The secret stays
inside encrypted Terraform state and Cloudflare; it is never sent to Claude,
ChatGPT, Mattermost, a phone, or a user laptop.

No interactive upstream authorization is required. After apply, AI Controls
uses these headers for both capability synchronization and Portal-to-upstream
requests:

- `CF-Access-Client-Id`
- `CF-Access-Client-Secret`

The Portal mapping keeps `on_behalf = false`. A human authenticates only to
`tools.yourown.chat` using Portal Managed OAuth and is not prompted separately
for Terraform or Google Cloud. The MCP processes still use their own
in-cluster workload credentials for calls to HCP Terraform and Google Cloud.

Continue only after all AI Controls entries show `Ready` and a non-zero tool
count. Every successful MCP production rollout forces capability
synchronization so new and renamed tools become visible immediately. `Waiting`
means Cloudflare cannot yet initialize the upstream MCP session; inspect the
status error and verify the direct hostname and Access policy.

The service token lasts one year (`8760h`); rotate it before expiry by replacing
the resource through Terraform. The temporary shared token is intentional—split
it into one token and least-privilege policy per MCP server when the role model
is implemented.

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
