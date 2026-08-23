# Infrastructure-as-code policy

Persistent cloud, cluster, edge, identity, database, delivery, and security
configuration must be declared in its authoritative infrastructure-as-code
source.

Manual control-plane mutations are not an implementation path. An explicitly
authorized emergency mutation must be recorded and reconciled into the
authoritative declarative configuration before the task is complete.

Durable platform infrastructure is declared in Terraform. Application runtime
and delivery manifests are declared in their authoritative Helm and Skaffold
sources. A change made only through a console, local CLI, direct API,
`kubectl apply`, or `helm upgrade` is not a completed implementation.

A task that encounters or creates configuration drift remains incomplete until
the drift is reconciled or explicitly handed to an authorized operator with
the affected resource, observed state, intended state, and required next
action recorded.

## Mutation lifecycle

Every infrastructure mutation follows this lifecycle: source change,
permitted offline validation, remote plan through the approved MCP, review of
the exact plan, explicit authorization, application of that reviewed plan, and
remote verification.

A plan becomes invalid if its source revision, variables, dependency outputs,
state, target Stack, or intended scope changes after review. The agent must
create and present a new plan instead of applying the stale plan.

Only one apply may operate on the same Stack or state at a time. Dependent
Stacks are applied and verified in their documented ownership order. A
successful apply is not complete until its remote state and intended downstream
effects have been verified through the approved MCP.

## Cross-Stack output ordering

A required upstream output is a hard dependency contract and an apply-order
boundary. A downstream Stack must not weaken, remove, defer, duplicate, disable,
or make that dependency conditional merely to make validation or planning
succeed before the upstream Stack has published it. Prohibited bypasses include
a literal `null`, `try()`, `can()`, a default, a placeholder, a copied value, an
empty collection, or a temporary feature-disable switch.

When a change introduces or starts consuming a required cross-Stack output,
the operator:

1. creates and reviews the upstream plan;
2. obtains explicit authorization, applies the upstream Stack, and verifies
   through the approved MCP that the exact output is present, non-null, and
   satisfies its documented type, shape, and invariants in remote state;
3. creates a fresh downstream plan against the published output; and
4. separately reviews and authorizes the downstream apply.

When merging or promoting the downstream wiring would automatically create an
invalid plan, that wiring remains unmerged or unpromoted until the upstream
apply and output verification succeed. The downstream change may be prepared
and reviewed in the meantime, but only a fresh plan created after publication
is eligible for approval.

Changing a consumed output's value, type, availability, sensitivity, or
dependency state invalidates a previously reviewed downstream plan. Approval of
the upstream apply does not authorize the downstream apply. If the required
order cannot be completed, the downstream change remains blocked; it is not
made temporarily optional to bypass the dependency.

An output may be nullable only when the cross-Stack contract defines it as
genuinely optional and the downstream behavior without it is independently
valid, safe, and verified. Bootstrap timing, or reclassifying the dependency in
the same rollout solely to bypass ordering, does not make a required output
optional.

## Platform and application ownership

`platform-gcp` owns shared durable infrastructure, state, security foundations,
and platform services whose lifecycle survives application suspension,
replacement, or rollback.

`app-gcp` owns generic application delivery control planes, source-integration
resources, release identities, private service-catalog integration, and
disposable development dependencies whose lifecycle follows application
delivery. Service-specific Helm wrappers, values, and environment overlays
remain in the owning service repository.

Helm and Skaffold own the declarative runtime state of application workloads. A
resource does not move between owners merely because it can be paused.

Ownership is determined by state, blast radius, sharing, and lifecycle. A
feature name or current deployment status is not an ownership boundary.

## Operational classes

Every managed component has one documented operational class:

- `foundation`: not stopped by a normal cost-saving pause;
- `durable-service`: compute may stop while durable state and declarative
  resources remain;
- `application-runtime`: workload compute may scale to zero and later resume
  from the approved artifact and configuration;
- `ephemeral`: created for a bounded verification and removed automatically.

Pausing a component changes its declared operating state, not its ownership. A
pause preserves the state, identities, secrets, network references, artifact
digest, and audit history required for a verified resume.

Cost-saving suspension uses the authoritative declarative control plane and
approved MCP route. It must not be implemented by manually deleting resources
or scaling workloads outside their owning lifecycle.

Provisioning and suspension are separate states. An `enabled` control
determines whether a component is provisioned; a `paused` control or declared
replica count determines whether provisioned compute is running.

Resume restores the previously approved immutable artifact and configuration,
followed by readiness and functional verification.
