# Cloudflare operations

The `terraform/cloudflare` Stack owns the `yourown.chat` zone, edge security,
Origin CA and Authenticated Origin Pull certificates, Zero Trust Tunnel,
Access applications, AI Controls MCP registrations, and the shared MCP Portal.
Cloudflare provider 5.22.x is the supported baseline.

## API token permissions

The account-scoped token stored in the HCP Terraform varset requires:

- Cloudflare Tunnel: Edit
- Access: Apps and Policies: Edit
- Access: Organizations, Identity Providers, and Groups: Edit
- MCP Portals: Edit

Keep the existing zone-scoped DNS, SSL and Certificates, Zone Settings,
Single Redirect, and Zone WAF permissions.

## MCP Portal

Terraform explicitly manages the AI Controls Portal and its separate
`type = "mcp_portal"` Access application. The application owns the email allow
policy, Managed OAuth, dynamic client registration, and token lifetimes.
Interactive authorization of upstream MCP servers in the Cloudflare dashboard
is intentionally outside Terraform.

The client endpoint is:

```text
https://mcp.yourown.chat/mcp
```

### Initial server synchronization

After creating a server, Cloudflare must obtain one admin OAuth credential
before it can synchronize the server's tools and prompts. This interactive
authorization is required once per server and cannot be completed by the
Terraform provider:

1. Open **Zero Trust → Access controls → AI controls → MCP servers**.
2. For `mcp-terraform` and `mcp-google-cloud`, open **Edit → Authenticate
   server** and complete Cloudflare Access login as `ilya@papou.email`.
3. Select **… → Sync capabilities** for each server.
4. Continue only after both entries show `Ready` and a non-zero tool count.

`Waiting` means Cloudflare is still trying to fetch capabilities. If it does
not clear, hover over the status for the upstream error, reauthenticate, and
run **Sync capabilities** again. `Sync Required` means the stored admin refresh
token must be renewed. Cloudflare also refreshes capabilities automatically
approximately every two hours.

The Portal mapping keeps `on_behalf = false`, so the admin credential is used
both for catalog synchronization and Portal-to-upstream requests. A client
authenticates only to `mcp.yourown.chat`; it is not prompted to authorize the
Terraform and Google Cloud servers separately. The servers still use their
own in-cluster workload credentials for calls to HCP Terraform and Google
Cloud.

## DNSSEC registrar transfer

`yourown.chat` is transferring from GoDaddy to Cloudflare Registrar. While the
public registrar remains GoDaddy and the parent `.chat` zone has no DS record,
Cloudflare legitimately reports DNSSEC as `pending`. Do not add the DS record
manually at GoDaddy during the transfer.

Cloudflare Registrar will discover the zone's CDS/CDNSKEY records and publish
the DS record after the transfer completes. When both conditions below are
true, replace the temporary `ignore_changes = [status]` in
`modules/cloudflare/settings.tf` with `status = "active"`:

```bash
curl -fsSL https://rdap.org/domain/yourown.chat
dig +short DS yourown.chat @1.1.1.1
```

The RDAP response must identify Cloudflare as registrar and the DS query must
return the Cloudflare key.

## Stable Origin CA plans

Provider v5 models Origin CA certificate hostnames as an ordered ForceNew list.
The module sorts the full SAN list and reuses it for both the CSR and the
Cloudflare resource. Keep this normalization and `create_before_destroy`;
otherwise apex/wildcard ordering can cause repeated certificate rotations.
