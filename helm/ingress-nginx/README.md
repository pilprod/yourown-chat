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
| L4 IP allowlist | `values.yaml` `loadBalancerSourceRanges` → GCP firewall | Drops any packet whose source is not a Cloudflare IP. |
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
In the Cloudflare dashboard for the `yourown.chat` zone, create a **proxied**
(orange-cloud) record pointing at the reserved IP:

```
A     yourown.chat    <ingress_ip_address>   Proxied
```

(Optional AAAA if you enable an IPv6 LB. IPv4 is sufficient — Cloudflare serves
IPv6 clients from its edge regardless.)

### 3. TLS mode + origin cert (Full Strict)
1. Cloudflare → SSL/TLS → Overview → set mode to **Full (Strict)**.
2. Cloudflare → SSL/TLS → Origin Server → **Create Certificate** (Origin CA).
   Save the certificate (PEM) and private key (PEM).
3. Load both into Secret Manager (containers already created by Terraform):

```bash
gcloud secrets versions add yourown-chat-mattermost-origin-tls-cert --data-file=origin.pem
gcloud secrets versions add yourown-chat-mattermost-origin-tls-key  --data-file=origin.key
```

### 4. Authenticated Origin Pulls (per-hostname mTLS)
1. Generate a client cert/key for the origin to trust, and upload the cert to
   Cloudflare for `yourown.chat` via the per-hostname AOP API, then enable AOP
   for the hostname. See Cloudflare docs: *SSL/TLS → Origin Server →
   Authenticated Origin Pulls → Per-hostname*.
2. Load the **CA that signs Cloudflare's presented client cert** into Secret
   Manager so nginx can verify it:

```bash
gcloud secrets versions add yourown-chat-cloudflare-origin-pull-ca --data-file=origin-pull-ca.pem
```

`nginx.ingress.kubernetes.io/auth-tls-secret` on the Mattermost Ingress points at
the `cloudflare-origin-pull-ca` Secret (key `ca.crt`), materialised from that
Secret Manager secret by the CSI SecretProviderClass.

### 5. Install the controller
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

If they changed, update **both** `loadBalancerSourceRanges` and
`proxy-real-ip-cidr` in `values.yaml`, then re-apply the Helm release. Consider a
scheduled job (GitLab CI) that opens an MR when the upstream list drifts.

## Verifying the lock-down

```bash
# From a non-Cloudflare host, a direct hit to the origin IP must time out / reset:
curl -sS --max-time 5 https://<ingress_ip_address> --resolve yourown.chat:443:<ingress_ip_address> ; echo "exit=$?"

# Through Cloudflare it must succeed:
curl -sSI https://yourown.chat | head -1
```
