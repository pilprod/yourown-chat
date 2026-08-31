# Cloudflare operations

The `terraform/cloudflare` Stack owns the `yourown.chat` zone, edge security,
Origin CA and Authenticated Origin Pull certificates, Zero Trust Tunnel,
Access applications, AI Controls MCP registrations, and the shared MCP Portal.
Cloudflare provider 5.22.x is the supported baseline.

## kagent UI promotion routes

The Zero Trust tunnel publishes two Access-protected browser routes for the
kagent release lifecycle:

| Release stage | Browser endpoint | In-cluster upstream |
| --- | --- | --- |
| Development, before approval | `https://dev.kagent.yourown.chat` | `kagent-ui.kagent-dev.svc.cluster.local:8080` |
| Production, after approval | `https://kagent.yourown.chat` | `kagent-ui.kagent-system.svc.cluster.local:8080` |

Cloud Deploy promotes the same immutable kagent release from development to
production. Each stage runs an independent control-plane release in its own
namespace, so a later development upgrade cannot mutate the approved
production release.

This Cloudflare contract protects and routes only the kagent browser UI. It
does not carry Agent Host, agentgateway, A2A, or Temporal traffic, and local
agent connectivity must not depend on Cloudflare. Clusters without Cloudflare
can expose the same kagent control-plane APIs through their own authenticated
ingress without changing the local-agent transport protocol.

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

The intended security baseline is a 15-minute Managed OAuth access token. The
Portal Access session and its refresh grant both last two weeks (`336h`); keep
these values identical so an otherwise-valid refresh grant is not invalidated
by an earlier Access-session expiry. Claude, Codex, and other clients should
rotate their access tokens automatically throughout that period.

#### Temporary 24-hour Codex compatibility window

As of 2026-08-16, Terraform temporarily sets the MCP Portal access-token
lifetime to `24h`. Long-running Codex agent tasks have reproduced a routed MCP
OAuth failure in which a refreshed credential is persisted but an already
running client continues with a stale or rotated refresh token and receives
`invalid_grant`. The relevant upstream tracking issues are:

- [openai/codex#35006](https://github.com/openai/codex/issues/35006) — OAuth
  lifecycle umbrella;
- [openai/codex#14144](https://github.com/openai/codex/issues/14144) — an active
  session keeps stale refresh-token state after reauthentication;
- [openai/codex#17265](https://github.com/openai/codex/issues/17265) — routed MCP
  token refresh;
- [openai/codex#32229](https://github.com/openai/codex/pull/32229) — serialized
  proactive refresh improvement already merged, but not sufficient for every
  routed/Desktop lifecycle path.

This is a compatibility exception, not a repair for the refresh lifecycle. It
increases the useful lifetime of a stolen bearer token and delays policy or
revocation enforcement from at most 15 minutes to at most 24 hours. Its scope
is limited to human OAuth access to the MCP Portal at `tools.yourown.chat`; it
does not change the two-week session/refresh grant, direct upstream Access
applications, the AI Controls service token, Mattermost login, or Google login.
Existing client credentials do not necessarily inherit a changed lifetime:
after applying this policy, explicitly reauthorize and restart Codex.

Remove the exception only after the upstream issue is resolved **and** the fix
has passed the following local acceptance test:

1. Upgrade Codex to a build containing the verified OAuth lifecycle fix.
2. Restore `managed_oauth_access_token_lifetime` from `24h` to `15m` in
   `terraform/cloudflare/modules/zero-trust-portal-access/main.tf` and update
   the matching Terraform test expectation.
3. Run the module's Terraform tests and apply the `cloudflare` HCP Terraform
   Stack.
4. Log out and reauthorize `yourown-chat`, then restart Codex so the test uses a
   token minted under the restored 15-minute policy.
5. Keep an agent task active for at least 45–60 minutes and make successful MCP
   calls before and after at least two token boundaries. The task must neither
   receive `invalid_grant` nor require a restart or another login.
6. Confirm the Portal session and refresh grant remain `336h`, then record the
   verification in the change that removes this exception.

When the full two-week grant expires, its refresh token is revoked, or the user
selects **Sign out** on the Portal homepage, reauthorize the client explicitly:

```bash
codex mcp logout yourown-chat
codex mcp login yourown-chat
```

After an external CLI browser flow succeeds, restart the MCP server in the
ChatGPT desktop settings or restart the app before continuing an already-open
task. A running Codex task can retain its old in-memory OAuth credential and
reject the first refresh even though the new credential was persisted; this is
tracked upstream in
[openai/codex#14144](https://github.com/openai/codex/issues/14144). Then start a
new task and confirm that the `yourown-chat` tools are present. Do not extend
the temporary 24-hour exception or treat it as a permanent fix. Do not use a
local MCP client, `kubectl`, or `gcloud` as an operational fallback.

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
