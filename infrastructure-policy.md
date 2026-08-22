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

## Platform and application ownership

`platform-gcp` owns shared durable infrastructure, state, security foundations,
and platform services whose lifecycle survives application suspension,
replacement, or rollback.

`app-gcp` owns application delivery control planes, source integrations,
release identities, application-specific configuration, and disposable
development dependencies whose lifecycle follows application delivery.

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
