# Official agentgateway platform owner

This module is the only owner of the cluster-wide Kubernetes Gateway API and
the official agentgateway Kubernetes control plane. It intentionally creates
no application `Gateway`, route, or proxy policy. Those are workload delivery
resources owned by `app-gcp`.

Pinned upstream inputs:

- Gateway API standard channel `v1.6.0`:
  `https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml`
- Vendored asset SHA-256:
  `a557172e8348f758479e9ee4000bbbb4b4aa48302a6b73461823ea5349bad56d`
- Official OCI charts `oci://cr.agentgateway.dev/charts/agentgateway` and
  `oci://cr.agentgateway.dev/charts/agentgateway-crds`, both version `v1.5.0`,
  pinned respectively to `sha256:9216ce83965ad2ce0888014d14aac5e71333fd9d4057cd167da92b37630fbee1`
  and `sha256:3a6cf44559c612ac8afb7f867aace69bbd4cdba765f1def6377b7a3186c603e3`.
- Controller image `cr.agentgateway.dev/controller:v1.5.0` pinned to
  `sha256:319489cb86b7f901a52a3fc532ad07f136c92756f88cf02a4040909e20001120`.
- Proxy image `cr.agentgateway.dev/agentgateway:v1.5.0` pinned to
  `sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`.

The module is opt-in. The release asset is read locally and decoded by the
Kubernetes provider; Terraform performs no download or `local-exec` during
plan/apply. CRD destruction is blocked because application releases can retain
objects using those APIs.

The platform release binds write access only in `agentgateway-system`; it does
not create or write any application namespace. `app-gcp` later owns
`ate-system`, labels it for controller discovery, and binds the chart-generated
deployer ClusterRole there. This avoids both a namespace bootstrap cycle and a
cluster-wide write binding while keeping the platform/app ownership boundary
explicit. The chart's cluster-wide read role is an upstream controller
requirement and remains the documented exception.
