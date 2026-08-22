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

