# prod environment

Defined by the `deployment "prod"` block in
[`../../stacks/deployments.tfdeploy.hcl`](../../stacks/deployments.tfdeploy.hcl).

Posture: **production**. Regional (HA) GKE with on-demand `e2-standard-2`
nodes, `db-custom-2-8192` **regional** Cloud SQL, deletion protection on,
bucket `force_destroy` off.

Before first apply, replace in the deployment block:
- `project_id` → your real prod GCP project ID.
- `master_authorized_networks` → your CI runner / bastion CIDR (never
  `0.0.0.0/0`).

Consider enabling `require_approval` on the Cloud Deploy target and PITR on
Cloud SQL for prod.
