# Temporal component

This is the only Temporal-specific Terraform composition in the platform.
It is enabled by `app-gcp` and owns:

- the pinned official Temporal Helm chart (no custom image);
- the `temporal` and `temporal_visibility` logical Cloud SQL databases;
- the dedicated database user and CMEK Secret Manager password;
- the private-IP Kubernetes endpoint to Cloud SQL;
- schema setup/update jobs managed by the Terraform Helm release;
- the isolated namespace, network policy, quota and default limits;
- the CMEK result bucket used by the activity worker.

The component composes generic project modules from `terraform/modules`.
Database and bucket modules must not contain Temporal names, chart values or
workload policy. Conversely, Temporal must not be added to Skaffold, Cloud
Build image creation or Cloud Deploy: it is vendor platform infrastructure and
has a Terraform lifecycle.

Cloud SQL uses `ssl_mode = ENCRYPTED_ONLY`. Both Temporal SQL stores therefore
enable TLS. Hostname verification is disabled because the private Cloud SQL IP
is exposed inside Kubernetes through a local service name that is not present
in the managed server certificate.

The `agent_platform_runtime_enabled` switch scales only custom Go workloads.
It does not uninstall this component or remove durable history. Disabling
`agent_platform_enabled` is a destructive infrastructure decision and must be
planned separately.
