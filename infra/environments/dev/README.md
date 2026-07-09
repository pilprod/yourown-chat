# dev environment

Defined by the `deployment "dev"` block in
[`../../stacks/deployments.tfdeploy.hcl`](../../stacks/deployments.tfdeploy.hcl).

Posture: **cheapest**. Zonal GKE with Spot `e2-small` nodes, `db-f1-micro`
zonal Cloud SQL, deletion protection off, bucket `force_destroy` on.

Before first apply, replace in the deployment block:
- `project_id` → your real dev GCP project ID.
- `master_authorized_networks` → your CI runner / office CIDR (dev currently
  defaults to `0.0.0.0/0`, which is open — restrict it).

Auth is configured in HCP Terraform (OIDC dynamic credentials or a variable
set); no credentials are committed.
