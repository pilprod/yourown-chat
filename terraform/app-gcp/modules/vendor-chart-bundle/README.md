# Vendor chart bundle

This module is the product-neutral adapter for a service-owned vendor testbed.
It accepts an immutable OCI chart reference (including its digest), the
exact base64-encoded product-owned values and a typed placement/network model.
It does not carry vendor defaults or accept an untyped Helm-values escape hatch.

The adapter creates restricted namespaces with quotas, deny-by-default ingress
and egress, paired policies for every catalog flow, exact `/32` DNS, Kubernetes
API and private database allowances, and Secret Manager CSI bindings. DNS and
Kubernetes API egress cover both their Service ClusterIP and ready endpoint
addresses because policy enforcement may occur on either side of Service DNAT;
every IP destination remains an exact `/32`. The DNS policy also retains its
kube-system/kube-dns selector for implementations that preserve pod identity.
The application release stays absent until every declared database connection
secret ID has been published by the platform Stack. The CRD release is
independently pinned and has `prevent_destroy = true` because its resources are
cluster-wide.

The caller should instantiate one module per catalog bundle and pass:

- `bundle_key` and `bundle` from the app-gcp Stack inputs;
- `project_id`, `cluster_dns_ip` and `cloudsql_private_ip` from platform outputs;
- `database_secret_ids` from the platform's additional connection-secret map;
- non-sensitive ownership `labels`.

Only an explicitly declared bundle can open a source-to-destination path. Each declared path
produces both source egress and destination ingress policy; all undeclared paths
remain denied.
