# YourOwn.Chat private service catalog

Private HCP Terraform Stack `service-catalog` that publishes repository
connections and other private component inputs consumed by the public
platform Stacks in `pilprod/yourown-chat` through `upstream_input`. It also
owns private service names and in-cluster origins; the public platform only
implements their typed, reusable adapters.

This repository contains no credentials, tokens, or secret values. Secrets
stay in the approved secret control plane.

## Layout

- `terraform/service-catalog/` — Stack source (`variables`, `outputs`,
  `catalog.tfdeploy.hcl`). The deployment file holds the private literal values.

## Change control

A catalog change is a reviewed source change followed by a remote plan and
approved apply through the approved Terraform MCP. Dependent Stacks (`app-gcp`)
re-plan from the last-applied outputs; apply order is `service-catalog` then
`app-gcp`, then `cloudflare` when a private upstream changes.

`vendor_chart_bundles` is the typed private side of the reusable public vendor
adapter. The first entry is deliberately production-ineligible and pins the
product/source commits, digest-addressed Helm charts, exact product-owned
values bytes, namespaces, selectors, ports and Cloud SQL binding needed for the
stock testbed. Its candidate tag is only a reservation until the product
release owner creates it. `private_http_routes` remains disabled until the
in-cluster release is ready and then supplies Cloudflare Access with a typed
ClusterIP Service origin.
