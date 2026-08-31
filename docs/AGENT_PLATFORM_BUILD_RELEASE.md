# Agent platform build and release

The active agent runtime path is the Terraform-managed kagent/Substrate
testbed. The former custom Temporal-worker release rail has been removed from
`app-gcp`; it has no Stack inputs, Cloud Build trigger, Cloud Deploy pipeline,
Helm chart, namespace, Workload Identity binding or result bucket.

## Source ownership

- [`pilprod/kagent`](https://github.com/pilprod/kagent) owns the kagent fork
  used for integration changes.
- [`pilprod/substrate`](https://github.com/pilprod/substrate) owns the external
  local-agent substrate and its immutable release artifacts.
- [`pilprod/yourown-chat-agents`](https://github.com/pilprod/yourown-chat-agents)
  owns declarative agent definitions and agent-side integration code.
- `pilprod/yourown-chat-workflows` owns Temporal workflow and activity source.
  Its delivery lifecycle is separate and is not required for the local-agent
  testbed.
- This repository owns the Google Cloud resources, immutable pins, namespace
  policy and release handoff.

## Namespace contract

Agent workload namespaces are declared as a map in
`terraform/app-gcp/service-inputs.tfdeploy.hcl`. The initial entry is
`codex -> agent-codex`. Each entry receives restricted Pod Security labels,
default-deny ingress and egress, DNS-only baseline egress, quota and limit
policy. The kagent controller getter, writer and environment-source RBAC are
bound in every declared agent namespace; no controller-wide wildcard binding
is created.

Adding another agent means adding one reviewed map entry and its explicit
network permissions. It does not mean restoring a shared workload namespace.

## Immutable release path

1. Publish and verify the kagent fork artifacts according to
   [KAGENT_FORK_RELEASE.md](KAGENT_FORK_RELEASE.md).
2. Record digest-qualified kagent and Substrate inputs in
   `terraform/app-gcp/service-inputs.tfdeploy.hcl`.
3. Run the local render, checksum and Terraform validation gates.
4. Review and apply the `app-gcp` plan. Keep Terraform ownership of the current
   Helm release until the two-phase handoff documented in
   [KAGENT_SUBSTRATE_RELEASE.md](KAGENT_SUBSTRATE_RELEASE.md) is complete.
5. After handoff, release only through the `kagent-substrate` Cloud Deploy
   pipeline and its `kagent-substrate-testbed` target.

The pipeline is production-ineligible until its compatibility, native Secret
sync, ownership handoff and broker smoke gates are all satisfied. A local
agent test does not require a Temporal workflow deployment.

## Verification

```bash
bash terraform/app-gcp/test/per-agent-namespace-isolation.test.sh
bash terraform/app-gcp/test/substrate-bootstrap-gates.test.sh
bash helm/test/agent-routing.test.sh
terraform stacks -chdir=terraform/app-gcp validate
```

Operational activation and rollback details remain in
[KAGENT_SUBSTRATE_RELEASE.md](KAGENT_SUBSTRATE_RELEASE.md).
