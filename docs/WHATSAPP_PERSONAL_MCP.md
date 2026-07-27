# Personal WhatsApp MCP (QR-linked)

## Mandatory disclaimer

This is an unofficial client built on a reverse-engineered WhatsApp Web
protocol. Its operation can violate the WhatsApp Terms of Service regardless
of traffic volume or purpose. The controls below reduce accidental automation
and operational instability; they do not guarantee that the account will not
be restricted or banned. The supported path without this protocol risk is the
official WhatsApp Business Cloud API. This exception is accepted only for a
personal, low-volume account.

The server deliberately does not imitate human behaviour, generate background
presence/status activity, rotate proxies, bypass verification, or offer bulk,
broadcast, group, unknown-contact, or multi-account sending.

## Architecture and controls

`mcp-whatsapp-personal` is separate from `mcp-whatsapp-business`:

- Baileys `7.0.0-rc13` is pinned in the repository lock file and audited in
  Cloud Build;
- one `Recreate` pod owns one QR-linked session and one ReadWriteOnce PVC;
- the auth directory, bounded message index, send counters, emergency-stop
  state, and redacted JSONL audit log survive pod restarts;
- the PVC uses the `mcp-sensitive` StorageClass and the shared regional CMEK;
- the client refuses to start without an explicit static SOCKS5/SOCKS5H,
  HTTP, or HTTPS proxy on TCP 443 from Secret Manager;
- dev never opens a WhatsApp connection, preventing a parallel session from a
  disposable release;
- direct messages only: a peer must already have at least one captured inbound
  message;
- there is no multi-recipient tool;
- defaults are 6 sends/hour, 20/day, at least 30 seconds between sends, and at
  most two sends to a peer before another inbound reply;
- for the first seven days after the initial persisted QR link, the effective
  ceilings are automatically reduced to 2 sends/hour and 5/day;
- every send requires the literal MCP confirmation `SEND`;
- read receipts are explicit (`MARK_READ`) and are never automatic;
- `STOP` persistently disconnects the client and disables reconnection/sends;
  `RESUME` is a separate confirmed operation;
- reconnect starts at 30 seconds and uses exponential backoff up to ten
  minutes; the backoff resets only after a session stays open for 30 minutes,
  and logged-out or forbidden sessions do not reconnect automatically.

Message contents and JIDs are required in the private PVC-backed index so MCP
can read conversations. Application logs are silent for the Baileys client,
and the audit log stores only hashed peer identifiers and counters.

## Prerequisites

Choose one static residential/mobile proxy in the same normal region as the
phone. It must:

- be dedicated to this session and not rotate its egress IP;
- support WebSocket and HTTPS CONNECT traffic;
- listen on TCP 443 (the namespace NetworkPolicy permits no other external
  application port);
- preferably use `socks5h://` so name resolution happens at the proxy;
- never be used for a second simultaneous session for this number.

The infrastructure apply order is:

1. `platform-gcp` — creates the dedicated Workload Identity and grants the
   Compute Engine service agent access to the CMEK;
2. `app-gcp` — creates `mcp-sensitive`, the namespace, proxy Secret Manager
   container/IAM, and updated Cloud Deploy parameters;
3. `cloudflare` — adds the protected personal MCP upstream to the existing
   Portal/Tunnel;
4. an MCP release — builds and deploys the new image.

## Configure the proxy

Terraform seeds a disabled placeholder. Add the real URL as a new version; do
not put it in Git, Helm values, Terraform variables, Kubernetes Secrets, or
shell history:

```bash
read -r -s WHATSAPP_PROXY_URL
printf '%s' "${WHATSAPP_PROXY_URL}" |
  gcloud secrets versions add mcp-whatsapp-personal-proxy-url \
    --project=yourown-chat \
    --data-file=-
unset WHATSAPP_PROXY_URL
```

Examples of accepted formats:

```text
socks5h://USER:PASSWORD@proxy.example:443
https://USER:PASSWORD@proxy.example
```

Restart only `deployment/mcp-whatsapp-personal` after rotating the proxy
secret so the CSI volume remounts `versions/latest`. Never rotate the proxy
while the WhatsApp session is active.

## Link the device

The production health endpoint proves that the MCP process is alive. The
production protocol smoke additionally fails if the proxy is still the seeded
placeholder. Linking remains a one-time operator action:

1. Connect the Cloudflare Portal (`https://tools.yourown.chat/mcp`) in the MCP
   client. Mattermost uses the same Portal; direct MCP Service URLs are blocked
   by namespace NetworkPolicy.
2. Call `whatsapp_personal_status`; expect `awaiting_qr`.
3. Call `whatsapp_personal_get_qr`; it returns a PNG.
4. On the phone open **WhatsApp → Settings → Linked devices → Link a device**
   and scan it.
5. Call `whatsapp_personal_status` again; expect `connected`.

Do not delete the PVC or auth directory during routine rollouts. A new QR is
required after an explicit WhatsApp logout, credential invalidation, or loss of
the auth state.

## MCP tools

- `whatsapp_personal_status`
- `whatsapp_personal_get_qr`
- `whatsapp_personal_list_conversations`
- `whatsapp_personal_list_messages`
- `whatsapp_personal_send_text`
- `whatsapp_personal_mark_read`
- `whatsapp_personal_emergency_stop`
- `whatsapp_personal_resume`
- `whatsapp_personal_reset_link` (requires an active stop and
  `RESET_LINK`; deletes only the linked-device auth directory)

The connector does not attempt to scrape or interpret WhatsApp account-warning
screens. A `forbidden` disconnect activates the persistent stop; any warning
visible on the phone must be treated as a manual emergency-stop signal.

## Why Cloudflare WARP does not replace the proxy

Consumer WARP and the default Cloudflare Zero Trust Gateway egress use shared
Cloudflare network addresses. They do not make a GKE workload appear to use the
phone's residential/mobile address, do not promise one account-stable source
IP, and therefore do not satisfy this connector's static residential/mobile
egress requirement.

Cloudflare dedicated egress IPs are static, but they are Cloudflare data-center
addresses and are available only as a Zero Trust Enterprise add-on. They solve
SaaS IP allowlisting, not residential/mobile reputation. Running the Linux
Cloudflare One Client in the pod would additionally require a tunnel daemon and
network-interface privileges that conflict with this workload's non-root,
read-only, capability-dropped security context.

Cloudflare source-IP anchoring can send WARP traffic through a `cloudflared`
connector at a location whose public address should be preserved. A connector
running on an always-on home network could therefore retain the home ISP egress
IP, but it adds a WARP client, Gateway policy, home connector, and another
availability dependency. It is not simpler than the current single static
proxy endpoint.

The preferred no-rented-proxy future option is an operator-owned always-on home
or mobile gateway that exposes one authenticated static SOCKS5H endpoint to
this pod. The endpoint may use a private overlay underneath, but WhatsApp must
ultimately see the stable home/mobile egress address. Until that gateway is
designed and tested, the current proxy contract remains unchanged.
