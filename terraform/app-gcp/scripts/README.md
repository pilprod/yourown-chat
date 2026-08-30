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
