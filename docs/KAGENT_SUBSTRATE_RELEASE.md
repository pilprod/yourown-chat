# kagent/Substrate testbed activation

This rail is a production-ineligible external-local-provider testbed. It keeps
the existing Terraform-managed `kagent` Helm release live while prerequisites
are prepared, then gives Cloud Deploy ownership only through a later reviewed
handoff. Do not combine the two ownership phases in one HCP Terraform run.

## Immutable Substrate semver handoff

The reviewed public `pilprod/substrate` `v0.0.22` release is recorded in
`helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json`
with an adjacent SHA-256 checksum. Its source commit is
`e9ed68e587b56df2aa2a7f0267a744598c4d48b4`; application and CRD charts plus
all release images and the agentgateway dependency are digest-qualified. This
is app-gcp consumer evidence, not a producer release asset, because that semver
workflow published OCI artifacts without `substrate-gke-preview.json`.

Validate and render only the Substrate portion with:

```sh
terraform/app-gcp/scripts/render-substrate-semver-consumer-pin-fragment.py \
  helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json
```

The output is intentionally incomplete. Do not set `bootstrap_enabled` or
`release_enabled` from this record: independent kagent evidence, compatibility
attestations, native Secret synchronization, ownership handoff and Broker smoke
gates remain separate reviewed inputs.

## Phase A: apply before any ownership forget

Phase A renames the Terraform address from
`helm_release.application` to `helm_release.application_handoff_source` with a
Terraform `moved` block. The Helm resource attributes are unchanged,
`vendor_chart_bundles.kagent.application_enabled` remains `true`, and
`kagent_substrate_delivery.release_enabled` remains `false`.

The first app-gcp HCP run for this commit must show only the address move for
the existing kagent application release: no Helm update, replacement, delete or
uninstall. Apply that run and verify `helm status kagent -n kagent-system`
before preparing Phase B. Phase B (`removed` plus `destroy = false`) is
intentionally absent from this commit and must not be added or applied until
the Phase A state move has completed.

## Native Secret source contract

Terraform creates or references eight Secret Manager containers, but never
reads their bytes. The operator rail synchronizes the following exact sources:

| Logical source | Secret Manager ID | Kubernetes Secret | Exact keys |
| --- | --- | --- | --- |
| `postgres` | `substrate-database-url` | `ate-system/substrate-cloud-sql` | `connection-string` |
| `api_tls` | `substrate-ate-api-tls` | `ate-system/substrate-ate-api-tls` | `server-credential-bundle.pem`, `client-ca.pem` |
| `controller_tls` | `substrate-ate-controller-tls` | `ate-system/substrate-ate-controller-tls` | `client-credential-bundle.pem`, `server-ca.pem` |
| `egress_gateway_tls` | `substrate-atenet-egress-server-tls` | `ate-system/substrate-atenet-egress-server-tls` | `server-credential-bundle.pem`, `server-ca.pem` |
| `egress_authorizer_tls` | `substrate-atenet-egress-client-tls` | `ate-system/substrate-atenet-egress-client-tls` | `client-credential-bundle.pem`, `server-ca.pem` |
| `actor_id_jwt_pool` | `substrate-actor-id-jwt-pool` | `ate-system/actor-id-jwt-pool` | `pool` |
| `actor_id_ca_pool` | `substrate-actor-id-ca-pool` | `ate-system/actor-id-ca-pool` | `pool` |
| `kagent_client_tls` | `kagent-ate-client-tls` | `kagent-system/kagent-ate-client-tls` | `client-credential-bundle.pem`, `server-ca.pem` |

The chart also always mounts `ate-system/actor-id-ca-certs` key `ca.crt`.
There is deliberately no ninth Secret Manager container: the operator derives
that cert-only Secret from `actor_id_ca_pool.pool` at
`CAs[0].RootCertificateDER`, verifies it is currently valid, permits certificate
signing, has `CA:TRUE`, and has a public key matching the pool signing key, then
verifies the applied bytes exactly.

`native_secret_sync_ready` means all eight source Secrets and this derived
ninth Kubernetes Secret are valid. Leave it `false` after any partial or failed
run.

## Owner-only operator bundle

The first bootstrap requires one local JSON bundle with schema
`yourown.chat/kagent-substrate-native-secret-bundle/v1`. It contains exactly
`schema`, `projectId`, and the eight `secrets` records from the table. The
PostgreSQL record uses `source: "existing-raw"` and carries no data; its current
value is read from `substrate-database-url`. Each of the other seven uses
`source: "operator-envelope-v1"` and an exact `data` map whose values are
canonical base64 of the file bytes. Base64 is encoding, not encryption.

A record has this shape (use the exact IDs, namespace, name and keys from the
table):

```json
{
  "secretManagerId": "substrate-ate-api-tls",
  "namespace": "ate-system",
  "kubernetesName": "substrate-ate-api-tls",
  "source": "operator-envelope-v1",
  "data": {
    "server-credential-bundle.pem": "BASE64_FILE_BYTES",
    "client-ca.pem": "BASE64_FILE_BYTES"
  }
}
```

Create the bundle outside every Git worktree, set mode `0600`, and keep it on
an owner-controlled encrypted volume. The script rejects symlinks, a different
owner, any group/other permission bit, duplicate or additional JSON keys,
wrong IDs, and any bundle path inside any Git worktree or Git metadata
directory. The MVP actor CA pool is root-only and rejects non-empty
`IntermediateCertificatesDER`. Secret bytes are passed
to Google Secret Manager through `--data-file` and to Kubernetes through
server-side apply on stdin; they do not enter HCL, Terraform plans or Terraform
state. The script uses a private temporary directory and deletes it on exit.

## Validate, bootstrap and rotate

Required local commands are Bash, Python 3, `jq`, OpenSSL, ripgrep, the standard
POSIX command-line tools, `gcloud` and `kubectl`. The operator needs `get`,
`versions.access` and `versions.add` on the eight fixed Secret Manager
containers, and `get`/`patch` for Secrets in only `ate-system` and
`kagent-system`, plus `create` for the initial materialization. Because the
preflight verifies both namespaces, the kube identity also needs cluster-scoped
`get` on `namespaces`. All permissions are checked before any new Secret
Manager version is uploaded.

Validate without external writes:

```sh
terraform/app-gcp/scripts/bootstrap-kagent-substrate-secrets.sh validate \
  --project yourown-chat \
  --bundle /secure/kagent-substrate-native-secrets.json
```

After the bootstrap HCP run has created both namespaces and all containers,
add seven envelope versions and synchronize all nine Kubernetes Secrets:

```sh
terraform/app-gcp/scripts/bootstrap-kagent-substrate-secrets.sh bootstrap \
  --project yourown-chat \
  --context gke_yourown-chat_europe-west3-b_europe-west3-b \
  --bundle /secure/kagent-substrate-native-secrets.json
```

For later reconciliation from existing Secret Manager versions, no local
bundle is accepted:

```sh
terraform/app-gcp/scripts/bootstrap-kagent-substrate-secrets.sh sync \
  --project yourown-chat \
  --context gke_yourown-chat_europe-west3-b_europe-west3-b
```

Both write modes validate every payload before Kubernetes mutation. Checks
cover PostgreSQL URI shape, closed pool JSON, pool private-key/certificate
matching, credential-bundle order, key/leaf matching, trust chains, TLS EKU,
and these identities:

- server DNS SANs `api.ate-system.svc` and
  `atenet-egress.ate-system.svc`;
- controller URI SAN
  `spiffe://cluster.local/ns/ate-system/sa/ate-controller`;
- atenet URI SAN
  `spiffe://cluster.local/ns/ate-system/sa/atenet-egress`;
- kagent URI SAN
  `spiffe://cluster.local/ns/kagent-system/sa/kagent-controller`.

The script prints only Secret names and Secret Manager version resource names.
It never changes `native_secret_sync_ready`; that attestation belongs in a
separate reviewed app-gcp HCP run after the operator evidence is checked.

## Local-provider-only network mode

This MVP intentionally tests external local Codex/Claude providers and does not
test Actor/MCP egress. `kagent_substrate_delivery.local_provider_only=true`
therefore requires an empty `atenet_egress_destinations` map and creates no
external atenet NetworkPolicy route. The default remains `false`: with that
default an enabled bootstrap requires at least one explicit reviewed CIDR and
port, while `0.0.0.0/0` and `::/0` remain forbidden.

## No-port-forward enrollment rail

The long-lived local Agent Host uses the public Broker without a port-forward.
Initial external-provider enrollment is issued separately with
`terraform/app-gcp/scripts/issue-substrate-external-provider-enrollment.sh`.
That helper verifies the Terraform-managed persistent default-deny policy,
runs either the exact verified Substrate `v0.0.22` native `kubectl-ate` binary
or the legacy digest-pinned image in a restricted in-cluster Pod, talks only to
`api.ate-system.svc:443`, and publishes the single-use credential into an
owner-only local file. The native binary is selected for the explicit Linux
node architecture, checked against immutable GitHub release metadata,
checksums, annotated tag/source identity and pinned extracted-binary digest,
then streamed through `kubectl exec -i` into a memory-backed `emptyDir`. This
requires no GitHub authentication; an existing authenticated modern `gh` CLI
adds signed immutable-release attestation verification without any login or
refresh action. The helper does not pass credential bytes through Terraform
state, a Kubernetes Secret, ConfigMap, Pod logs, command arguments, or a
port-forward.

The enrollment helper is not part of the native Secret bootstrap and does not
change any activation attestation. Run it only after the app-gcp bootstrap
prerequisites and the reviewed immutable transfer image digest exist.
