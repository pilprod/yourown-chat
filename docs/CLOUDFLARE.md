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
https://mcp.yourown.chat/mcp
```

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
`mcp.yourown.chat` using Portal Managed OAuth and is not prompted separately
for Terraform or Google Cloud. The MCP processes still use their own
in-cluster workload credentials for calls to HCP Terraform and Google Cloud.

Continue only after both AI Controls entries show `Ready` and a non-zero tool
count. `Waiting` means Cloudflare cannot yet initialize the upstream MCP
session: inspect the status error, verify the direct hostname and Access
policy, then select **… → Sync capabilities**. The service token lasts one
year (`8760h`); rotate it before expiry by replacing the resource through
Terraform. The temporary shared token is intentional—split it into one token
and least-privilege policy per MCP server when the role model is implemented.

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
