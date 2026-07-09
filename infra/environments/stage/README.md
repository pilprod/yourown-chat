# stage environment

Defined by the `deployment "stage"` block in
[`../../stacks/deployments.tfdeploy.hcl`](../../stacks/deployments.tfdeploy.hcl).

Posture: **pre-production**. Zonal GKE with Spot `e2-medium` nodes,
`db-custom-1-3840` zonal Cloud SQL, deletion protection on.

Before first apply, replace in the deployment block:
- `project_id` → your real stage GCP project ID.
- `master_authorized_networks` → your CI runner CIDR.
