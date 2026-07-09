# Environments

In the Terraform **Stacks** model an environment is a **deployment**, not a
separate root module. All three environments are therefore defined as
`deployment "<env>"` blocks in [`../stacks/deployments.tfdeploy.hcl`](../stacks/deployments.tfdeploy.hcl),
which is the single source of truth for per-environment values.

These folders hold documentation and the intended posture for each environment
so reviewers can see the differences at a glance. Editing values here has no
effect — change the matching deployment block.

| Setting                | dev            | stage             | prod                |
|------------------------|----------------|-------------------|---------------------|
| GKE topology           | zonal          | zonal             | regional (HA)       |
| GKE nodes              | spot e2-small  | spot e2-medium    | on-demand e2-std-2  |
| Cloud SQL              | f1-micro zonal | custom-1 zonal    | custom-2 regional   |
| Deletion protection    | off            | on                | on                  |
| Control-plane access   | open (dev)     | CI CIDR           | CI CIDR             |
| Bucket force_destroy   | on             | off               | off                 |

Promotion flows dev → stage → prod through the single Cloud Deploy delivery
pipeline; infrastructure is promoted by applying each deployment in HCP.
