# app-gcp input helpers

`render-substrate-preview-pin-fragment.sh` is a read-only bridge from the
Substrate `substrate-gke-preview.json` release artifact to the immutable fields
of an app-gcp vendor chart bundle. It writes HCL only to standard output and
does not edit `service-inputs.tfdeploy.hcl`, Helm values, or Terraform state.

The helper takes exactly three paths:

```sh
terraform/app-gcp/scripts/render-substrate-preview-pin-fragment.sh \
  /path/to/substrate-gke-preview.json \
  helm/vendor/substrate/crds.values.yaml \
  helm/vendor/substrate/application.values.yaml \
  > /tmp/substrate-preview-pins.hcl
```

The downloaded `substrate-gke-preview.json.sha256` must be beside the manifest.
The helper verifies that producer checksum, the closed
`yourown.chat/substrate-gke-preview/v1` schema, the closed source allowlist
(`pilprod/substrate` only), the
source/image-registry/image-tag relationship, every image
and chart digest/reference/version relationship, and the application values'
exact `image.registry`, `image.digests` and dependency
`images.agentgateway` handoff. The closed manifest and values must include the
chart-consumed `ateapi`, `atecontroller`, and `atenet` images plus the
digest-qualified agentgateway sidecar; missing or mismatched pins are rejected.
JSON and YAML duplicate keys are rejected. Both values files must be alias-free
YAML mappings with unique scalar keys directly below
`helm/vendor/substrate`; their exact byte hashes are emitted in the fragment.
The checksum detects artifact corruption but is bundled with the manifest, so
it is not a signature and does not prove that `source.commit` is reachable from
an approved public ref. Obtain both files from the reviewed release run and
complete that independent provenance gate before changing the active bundle.
The fragment's `image_digests` contains every chart-consumed pin: `ateapi`,
`atecontroller`, `atenet`, and the digest extracted from the full
`images.agentgateway` reference. The separately consumed `ateom-gvisor` digest
remains fully validated and is emitted as a digest-qualified provenance
comment, not misrepresented as a chart value.

The output is deliberately not a complete `vendor_chart_bundles.substrate`
entry. The release manifest cannot determine the reviewed `provisioned`,
`application_enabled`, `candidate_tag`, `product_commit`,
`supported_agent_runtimes`, `namespaces`, `endpoints`, `external_sources`,
`flows`, `kubernetes_api_egress_from`, or `database_bindings` fields. The
manifest's digest-qualified `ateom-gvisor` image also belongs in a separately
reviewed WorkerPool resource; the Substrate chart does not create that
environment resource. The helper reports these omissions on standard error and
never fills them with placeholders or defaults.

## External-provider enrollment without port-forwarding

`issue-substrate-external-provider-enrollment.sh` issues the single-use local
Agent Host enrollment through the in-cluster ate-api service. It creates one
unique restricted Pod, one policy ConfigMap and one deny-by-default
NetworkPolicy in the Substrate namespace, then removes all three on success or
failure. It never creates a Kubernetes Secret for the credential, opens a
port-forward, writes credential bytes to logs, or routes them through
Terraform state. The only allowed Pod egress is exact cluster DNS peers plus
the verified `kube-system/kube-dns` Service ClusterIP `/32` on TCP/UDP 53, and
`app=ate-api-server` on TCP 443. No broad CIDR is admitted.

The tracked Substrate Helm values admit the fixed enrollment Pod labels to the
ate-api NetworkPolicy. The script requires the internal endpoint, TLS SNI and
projected ServiceAccount audience to agree exactly as
`api.<substrate-namespace>.svc[:443]`. In the current release those values are
`api.ate-system.svc:443` and `api.ate-system.svc`. The selected ServiceAccount
must already be listed in `externalProviderEnrollmentAdmins`; app-gcp creates
`ate-system/ate-enrollment-admin` for this purpose.

Before running it:

1. obtain the reviewed release's exact digest-qualified `kubectl-ate` image;
2. choose a reviewed minimal transfer image which supplies POSIX `sh`, `sleep`,
   `test`, `mkdir`, `chmod`, and `cat` and runs as uid/gid 65532;
3. save the reviewed slot policy in a real, current-user-owned regular file
   with mode `0400` or `0600`; and
4. create a real current-user-owned output directory with no group/other
   permissions. The destination file must not exist.

No placeholder digest is checked in. After the Substrate release supplies the
real pins, invoke the helper with environment variables that came from that
reviewed handoff:

```sh
terraform/app-gcp/scripts/issue-substrate-external-provider-enrollment.sh \
  --kubectl-ate-image "${KUBECTL_ATE_IMAGE}" \
  --transfer-image "${TRANSFER_IMAGE}" \
  --context gke_yourown-chat_europe-west3-b_europe-west3-b \
  --cluster-dns-ip "${CLUSTER_DNS_IP}" \
  --namespace ate-system \
  --service-account ate-enrollment-admin \
  --api-endpoint api.ate-system.svc:443 \
  --server-name api.ate-system.svc \
  --ca-secret substrate-ate-controller-tls \
  --owner-atespace tenant-a \
  --worker-namespace external-workers \
  --worker-pool local-agents \
  --max-slots 2 \
  --policy-file /absolute/private/slot-policy.yaml \
  --ttl 1h \
  --output-file /absolute/private/enrollment-token
```

The main container writes an atomic `0600` credential into a memory-backed
shared volume. A non-logging transfer sidecar waits for that file. Only after
the main container terminates successfully and the file is present does the
local script stream it directly into a same-directory `0600` temporary file.
It publishes the final path with a hard link, so a concurrent file creation is
never overwritten. The credential file itself must remain the sole handoff to
the Agent Host.
