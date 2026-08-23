# YourOwn.Chat private service catalog

Private HCP Terraform Stack `service-catalog` that publishes repository
connections and other private component inputs consumed by the public
platform Stacks in `pilprod/yourown-chat` through `upstream_input`.

This repository contains no credentials, tokens, or secret values. Secrets
stay in the approved secret control plane.

## Layout

- `terraform/service-catalog/` — Stack source (`variables`, `outputs`,
  `catalog.tfdeploy.hcl`). The deployment file holds the private literal values.

## Change control

A catalog change is a reviewed source change followed by a remote plan and
approved apply through the approved Terraform MCP. Dependent Stacks (`app-gcp`)
re-plan from the last-applied outputs; apply order is `service-catalog` then
`app-gcp`.
