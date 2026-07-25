# Cloudflare provider v5 migration

The existing HCP Terraform `cloudflare` Stack remains the single owner of the
Cloudflare zone, DNS, Tunnel, Access applications, and Access organization.
Do not create a replacement Stack and do not import the same objects into a
second state.

The migration requires two separately reviewed and applied changes. Provider
v5 removed `cloudflare_zone_settings_override`, so Terraform must first forget
that aggregate v4 state object without changing the remote settings.

## Phase 1 — remove only the legacy state object

Phase 1 is complete:

- provider 4.x removed `cloudflare_zone_settings_override.this` from state
  through `removed { destroy = false }`;
- the remote settings remained active;
- DNSSEC and every other Cloudflare resource remained managed.

Before applying, make a state-version bookmark or download the current state
from HCP Terraform. Then review the speculative plan for the `cloudflare`
Stack. The only zone-settings action must say that

```text
module.cloudflare.cloudflare_zone_settings_override.this
```

is removed from Terraform state and **will not be destroyed**. Stop if the
plan proposes deleting or recreating DNS records, the Tunnel, Access
applications, Access policies, certificates, or the Zero Trust organization.

Apply phase 1 and verify:

```bash
curl -fsSIL https://yourown.chat
curl -fsSIL https://dev.yourown.chat
curl -fsSIL https://mcp-google-cloud.yourown.chat/mcp
curl -fsSIL https://mcp-terraform.yourown.chat/mcp
```

The public site must remain available. Access-protected hosts may return an
authentication response; they must not return a DNS or Tunnel error. Do not
make unrelated Cloudflare changes between phases.

## Phase 2 — migrate provider and enable MCP OAuth

The repository is now in phase 2 and pins Cloudflare provider 5.22.x. The
migration was reviewed manually against the provider schema instead of
applying `tf-migrate` output verbatim.

Phase 2:

1. update the root and child-module constraints and lock file to the selected
   Cloudflare provider 5.x release;
2. rename resource addresses using generated `moved` blocks, including
   `cloudflare_record` to `cloudflare_dns_record` and the Access organization
   v5 resource name;
3. import each formerly aggregated zone setting as an individual
   `cloudflare_zone_setting` resource;
4. keep the Tunnel ingress as a real `config.ingress` value and replace the
   obsolete `tunnel_token` argument with `tunnel_secret`;
5. move application policies inline into each
   `cloudflare_zero_trust_access_application`; applying an Access application
   without its existing policy inline can remove that policy;
6. enable Managed OAuth and dynamic client registration on the
   `mcp-google-cloud` and `mcp-terraform` Access applications, while keeping
   `dev.yourown.chat` as a normal browser application;
7. registers those two origins in one Cloudflare MCP Portal and publishes the
   proxied `mcp.yourown.chat` CNAME to `gateway.agents.cloudflare.com`;
8. creates dedicated `type = "mcp"` Access applications so the existing email
   allow-list controls server discovery through the Portal.

The Managed OAuth redirect allow-list will include:

```text
https://claude.ai/api/mcp/auth_callback
https://chatgpt.com/*
https://playground.ai.cloudflare.com/*
https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback
```

Localhost and loopback clients are admitted through the separate
`allow_any_on_localhost` and `allow_any_on_loopback` switches.

Use a 15-minute access-token lifetime and a two-week grant session. The
Cloudflare API token needs account-level edit permissions for Access
applications/policies, Cloudflare Tunnel, and MCP Portals, plus the existing
zone permissions.

The phase-2 plan must not replace existing DNS, Tunnel, Access, certificate,
or organization objects. Expected remote changes are the new portal/DNS
record, OAuth configuration updates on the two MCP applications, and
individual management of the already-effective zone settings.

### Single Stack deployment with deferred Portal adoption

Cloudflare creates a `type = "mcp_portal"` Access application as a side effect
of creating the Portal, but its UUID is not exposed by the Portal Terraform
resource. The Stack resolves this without a manual UUID or a second deployment:

1. `component.zero_trust` creates the Portal;
2. a bounded 20-second consistency wait lets the separate Access API observe
   Cloudflare's automatically generated application;
3. a data source lists the account's Access applications without relying on
   Cloudflare's eventually-consistent domain filter, then discovers the portal
   by type plus name/hostname;
4. its computed UUID is passed to `component.zero_trust_portal_access`;
   because the import ID is unknown during the initial plan, HCP Terraform
   defers the entire dependent component;
5. its declarative `import` adopts the generated UUID and applies the email
   allow policy, Managed OAuth, dynamic client registration, and token
   lifetimes.

Approve the phase-2 deployment once. HCP Terraform will show the Portal Access
component as deferred and automatically run its follow-up convergence plan.
The dependent module requires exactly one `type = "mcp_portal"` application
for `mcp.yourown.chat` and fails closed if Cloudflare returns zero or multiple
matches.

The initial plan must not replace existing DNS records, the Tunnel, direct
Access applications, certificates, or the Zero Trust organization. Expected
changes are state address moves, imports of the existing individual zone
settings, inline migration of the existing policies, Managed OAuth updates,
the two AI Controls server registrations, their dedicated policy applications,
and the new Portal/CNAME. The convergence plan may only import and update the
Cloudflare-generated Portal Access application.

Provider v5 emits `Resource Destruction Considerations` for every
`cloudflare_zone_setting` because Cloudflare exposes these settings as
non-deletable zone singletons. This warning is informational: the migration
imports every existing setting using `<zone_id>/<setting_id>` and then manages
its value. Removing such a resource later would stop Terraform management; it
would not delete the remote Cloudflare setting.

The `Some objects will no longer be managed` warning is also expected only for
the three old application-scoped policy addresses. Their `removed` block uses
`destroy = false`, while the same `allowed-emails` policies are declared inline
on the corresponding v5 Access applications in the same plan. Stop if the plan
shows those applications with an empty `policies` value or proposes deleting
the remote policies.

Finally, open **Zero Trust → Access controls → AI controls → MCP servers** and
complete the one-time upstream OAuth authorization for each server. Interactive
OAuth consent cannot be performed by Terraform. Then verify:

```bash
curl -i https://mcp.yourown.chat/mcp
curl -fsS https://mcp.yourown.chat/.well-known/oauth-authorization-server
```

The unauthenticated MCP request must return an OAuth challenge (`401` with
`WWW-Authenticate`), not a browser-login `302`. Add
`https://mcp.yourown.chat/mcp` once in Claude web settings; the cloud connector
is then available in Claude Desktop and mobile as well.

## Imports and recovery

Existing resources do not need manual imports: HCP state, provider state
upgraders, explicit `moved` blocks, and the policy `removed` block preserve
their identity. The only planned import is the Portal Access application that
Cloudflare creates before the deferred component's convergence plan.

If phase 1 was applied but phase 2 must be postponed, the Cloudflare settings
remain active remotely but are temporarily unmanaged. Resume phase 2 before
changing them. Restore an HCP state version only to recover from an actual
state error; do not use state restoration to roll back normal Cloudflare API
changes.
