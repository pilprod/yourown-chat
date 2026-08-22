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
