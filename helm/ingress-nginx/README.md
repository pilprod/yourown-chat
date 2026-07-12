# Public ingress — Cloudflare-fronted origin for `yourown.chat`

The prod Mattermost is published at **https://yourown.chat** through Cloudflare.
The GKE origin is locked down so that **only our Cloudflare zone** can reach it.

```
Internet ──▶ Cloudflare (TLS + WAF) ──▶ GCP static IP ──▶ ingress-nginx ──▶ Mattermost
                                        (only CF IPs         (mTLS +
                                         admitted at L4)      Full Strict)
```

## Layers of protection

| Layer | Where | Effect |
|-------|-------|--------|
| L4 IP allowlist | `values.yaml` `loadBalancerSourceRanges` → GCP firewall | Drops any packet whose source is not a Cloudflare IPv4 proxy IP. |
| mTLS (Authenticated Origin Pulls) | `mattermost.yaml` `auth-tls-*` annotations + `cloudflare-origin-pull-ca` Secret | Origin completes the handshake only when the caller presents **our zone's** client cert. Closes the shared-Cloudflare-IP gap. |
| Full (Strict) TLS | `mattermost.yaml` `tlsSecret: mattermost-origin-tls` | Cloudflare validates the origin cert (Cloudflare Origin CA) over HTTPS. |

> The IP allowlist alone is **not** sufficient: Cloudflare's proxy IPs are shared
> across every Cloudflare tenant, so without mTLS any Cloudflare customer could
> proxy to our origin IP. Use **per-hostname** Authenticated Origin Pulls (your
> own client cert), not zone-level (which shares Cloudflare's global cert).

## One-time bootstrap

### 1. Reserve the IP (Terraform)
`public_ingress_enabled = true` is set for the prod deployment, so
`terraform apply` reserves the address. Read it back:

```bash
terraform output ingress_ip_address    # e.g. 34.x.x.x
```

Put that value in `values.yaml` (`controller.service.loadBalancerIP`).

### 2. Cloudflare DNS
When `public_ingress_enabled = true`, the stack's `cloudflare` component creates
the **proxied** (orange-cloud) apex `A` record for `yourown.chat` pointing at the
reserved ingress IP automatically — the IP is wired internally from the network
component's `ingress_ip_address`, so there is nothing to enter by hand:

```
A     yourown.chat    <ingress_ip_address>   Proxied
```

(Optional AAAA if you enable a separate IPv6 LB path. IPv4 is sufficient —
Cloudflare serves IPv6 clients from its edge regardless; keep the GKE
`loadBalancerSourceRanges` list IPv4-only because GCP rejects mixed-family
firewall source ranges.)

### 3. TLS mode + origin cert (Full Strict)

The SSL mode and the origin cert are managed by the stack's **`cloudflare`
component**: `cloudflare_ssl_mode = strict` sets Full (Strict), and
`cloudflare_manage_origin_cert = true` (default) issues the Cloudflare Origin CA
cert. The same apply writes that cert/key straight into the
`mattermost-origin-tls-cert` / `mattermost-origin-tls-key` Secret Manager secrets
(via the `secrets` component) — **no manual push, nothing to copy between runs.**

Prefer to keep the key out of Terraform? Set `cloudflare_manage_origin_cert =
false` and create the cert by hand instead (Cloudflare → SSL/TLS → Origin Server →
**Create Certificate**), then load the downloaded files:

```bash
gcloud secrets versions add mattermost-origin-tls-cert --data-file=origin.pem
gcloud secrets versions add mattermost-origin-tls-key  --data-file=origin.key
```

### 4. Authenticated Origin Pulls (per-hostname mTLS)
AOP is **off by default**. To turn it on:

1. Generate a client cert/key signed by **your own CA** — the Cloudflare edge
   presents this cert to the origin.
2. Feed the client cert/key to the stack as `cloudflare_aop_certificate` /
   `cloudflare_aop_private_key` and set `cloudflare_aop_enabled = true`. The
   `cloudflare` component uploads the per-hostname cert and enables AOP for
   `yourown.chat` — no manual Cloudflare API call.
3. Load the **CA that signed that client cert** into Secret Manager so nginx can
   verify the edge:

```bash
gcloud secrets versions add cloudflare-origin-pull-ca --data-file=origin-pull-ca.pem
```

`nginx.ingress.kubernetes.io/auth-tls-secret` on the Mattermost Ingress points at
the `cloudflare-origin-pull-ca` Secret (key `ca.crt`), materialised from that
Secret Manager secret by the CSI SecretProviderClass.

### 5. Install the controller

**Automated:** the app-gcp stack's `cluster_bootstrap` component installs this
release at cluster bootstrap and injects `loadBalancerIP` from the
platform-published ingress IP (no manual value). Manual fallback:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace -f helm/ingress-nginx/values.yaml
```

## Keeping the Cloudflare ranges current

Cloudflare's published ranges change occasionally. Regenerate the allowlist and
diff it against `values.yaml`:

```bash
{ curl -fsSL https://www.cloudflare.com/ips-v4; echo; curl -fsSL https://www.cloudflare.com/ips-v6; }
```

If they changed, update IPv4 ranges in `loadBalancerSourceRanges`, and update
both IPv4 and IPv6 ranges in `proxy-real-ip-cidr`, then re-apply the Helm
release. Consider a scheduled job (GitLab CI) that opens an MR when the upstream
list drifts.

## Verifying the lock-down

```bash
# From a non-Cloudflare host, a direct hit to the origin IP must time out / reset:
curl -sS --max-time 5 https://<ingress_ip_address> --resolve yourown.chat:443:<ingress_ip_address> ; echo "exit=$?"

# Through Cloudflare it must succeed:
curl -sSI https://yourown.chat | head -1
```
