# Cloudflare provider v5 migration

The existing HCP Terraform `cloudflare` Stack remains the single owner of the
Cloudflare zone, DNS, Tunnel, Access applications, and Access organization.
Do not create a replacement Stack and do not import the same objects into a
second state.

The migration requires two separately reviewed and applied changes. Provider
v5 removed `cloudflare_zone_settings_override`, so Terraform must first forget
that aggregate v4 state object without changing the remote settings.

## Phase 1 — remove only the legacy state object

This repository is currently in phase 1:

- the provider constraint and lock file remain on Cloudflare provider 4.x;
- `cloudflare_zone_settings_override.this` has been replaced with a
  `removed` block whose `destroy` value is `false`;
- DNSSEC and every other Cloudflare resource remain managed.

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

Start phase 2 only after phase 1 has been applied successfully. Use the
official Cloudflare `tf-migrate` tool as a migration aid, then review its
output rather than applying it verbatim.

Phase 2 will:

1. update the root and child-module constraints and lock file to the selected
   Cloudflare provider 5.x release;
2. rename resource addresses using generated `moved` blocks, including
   `cloudflare_record` to `cloudflare_dns_record` and the Access organization
   v5 resource name;
3. recreate each formerly aggregated zone setting as an individual
   `cloudflare_zone_setting` resource;
4. keep the Tunnel ingress as a real `config.ingress` value and replace the
   obsolete `tunnel_token` argument with `tunnel_secret`;
5. move application policies inline into each
   `cloudflare_zero_trust_access_application`; applying an Access application
   without its existing policy inline can remove that policy;
6. enable Managed OAuth and dynamic client registration on the
   `mcp-google-cloud` and `mcp-terraform` Access applications, while keeping
   `dev.yourown.chat` as a normal browser application;
7. register those two origins in one Cloudflare MCP Portal and publish the
   proxied `mcp.yourown.chat` CNAME to `gateway.agents.cloudflare.com`.

The Managed OAuth redirect allow-list will include:

```text
https://claude.ai/api/mcp/auth_callback
https://chatgpt.com/*
https://playground.ai.cloudflare.com/*
http://localhost/*
http://127.0.0.1/*
```

Use a 15-minute access-token lifetime and a two-week grant session. The
Cloudflare API token needs account-level edit permissions for Access
applications/policies and Cloudflare Tunnel, plus the existing zone
permissions.

The phase-2 plan must not replace existing DNS, Tunnel, Access, certificate,
or organization objects. Expected remote changes are the new portal/DNS
record, OAuth configuration updates on the two MCP applications, and
individual management of the already-effective zone settings.

After apply, an unauthenticated request to an MCP endpoint must return an OAuth
challenge (`401` with `WWW-Authenticate`) rather than a browser-login `302`.
Add `https://mcp.yourown.chat/mcp` once in Claude web settings; the cloud
connector is then available in Claude Desktop and mobile as well.

## Imports and recovery

Normal migration does not need manual imports: the existing HCP state,
provider state upgraders, and explicit `moved` blocks preserve resource
identity. Imports are a recovery mechanism only if the phase-2 plan reveals
an object missing from state.

If phase 1 was applied but phase 2 must be postponed, the Cloudflare settings
remain active remotely but are temporarily unmanaged. Resume phase 2 before
changing them. Restore an HCP state version only to recover from an actual
state error; do not use state restoration to roll back normal Cloudflare API
changes.
