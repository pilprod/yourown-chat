# Agent platform architecture

This document is the canonical architecture and repository-boundary contract
for the YourOwn.Chat agent platform. Build, release and first-launch operations
are defined in [AGENT_PLATFORM_BUILD_RELEASE.md](AGENT_PLATFORM_BUILD_RELEASE.md).

## Repository boundaries

| Repository | Owns | Must not own |
|---|---|---|
| [`pilprod/yourown-chat`](https://github.com/pilprod/yourown-chat) | Public architecture, Terraform, Helm, Docker build definitions and delivery routing | Product backend, worker or MCP source code |
| [`pilprod/yourown-chat-server`](https://github.com/pilprod/yourown-chat-server) | `transport-api`, `auth-api`, `identity-api`, `identity-migrate`, `control-api`, independent users, Mattermost links, commands, approvals and Temporal state projection | Workflow/activity execution or MCP implementations |
| [`pilprod/yourown-chat-agents`](https://github.com/pilprod/yourown-chat-agents) | Temporal workflow and activity workers, deterministic orchestration, agent execution and replay tests | Client-facing authorization or infrastructure ownership |
| [`pilprod/yourown-chat-mcp`](https://github.com/pilprod/yourown-chat-mcp) | Go source for all owned MCP servers and their protocol/tool tests | Terraform, Helm or production credentials |

The source split is complete: `yourown-chat-server` builds the independently
deployable `transport-api`, `auth-api`, `identity-api`, `identity-admin`, `identity-migrate` and `control-api`;
`yourown-chat-agents` builds `workflow-worker` and `activity-worker`; and the
owned MCP implementations live only in `yourown-chat-mcp`.

## Runtime flow

```text
YourOwn.Chat client
  -> Mattermost + yourown-chat-server
  -> Temporal wire contract
  -> yourown-chat-agents workers
  -> authenticated MCP gateway
  -> isolated MCP server
  -> explicitly allowed external system
```

The server starts workflows, submits human decisions and reads state. Workers
consume Temporal task queues. They do not call each other directly or import
each other's internal Go packages. MCP servers expose tools; they do not own
workflow state, approvals or human conversation state.

## Shared contract

Workflow types, task-queue names, Temporal query/update names and serializable
input, state, decision, event and report schemas are versioned wire contracts.
Both application modules currently retain matching `internal/contracts` types.
A neutral schema becomes the generation source before contract version two.

An incompatible change is expanded and contracted:

1. the server reads old and new contract versions;
2. workers start writing the new version;
3. replay and compatibility tests cover existing histories;
4. support for the old version is removed only after its workflows complete.

## Identity and network boundaries

The application plane is split by trust zone: `edge` contains the short-named
`transport` and `auth` workloads; `identity` contains `api`, `admin` and
`migrate`; `control` contains `control`. Every namespace is
default-deny, and every cross-namespace edge
selects both the exact namespace and workload label.

- `transport-api`, `auth-api`, `identity-api`, `identity-migrate`, `control-api`, `workflow-worker` and
  `activity-worker` use separate Workload Identity service accounts and
  Kubernetes service accounts.
- The workflow worker talks only to Temporal. The activity worker receives only
  the explicitly required MCP/model/storage access.
- The identity service uses its own role and logical database in the existing
  smallest Cloud SQL instance. Its native `/v1` surface is cluster-private and
  reachable only through the X-Wing HPKE `transport-api`; administrative
  `/internal` routes remain isolated in a separate binary.
- Temporal has no public ingress and uses two logical databases on the private
  Cloud SQL address.
- MCP servers remain separate namespace tenants. A compromised MCP cannot reach
  another MCP or Mattermost through an internal service.
- Interactive identity and agent workload identity are never interchangeable.
- Risky mutations pause in Temporal and resume only with an auditable human
  approve/edit/reject decision.

## Lifecycle ownership

Temporal is platform infrastructure. Terraform installs the pinned official
chart, creates its databases, secret, result bucket, namespace, quota and
network policy from `platform-gcp`. It is not copied into Helm delivery and has
no custom image.

### Terraform ownership rule for future agents

Every durable resource has exactly one Stack owner. Before adding a Terraform
module or Stack, find the existing owner of the underlying resource and extend
that owner's module first. A feature name is not a valid reason to introduce a
parallel infrastructure module.

- `platform-gcp` owns GKE, the shared Cloud SQL instance and its logical
  databases/users, KMS, GCS platform buckets, Workload Identity and official
  platform services such as Temporal.
- `app-gcp` owns delivery rails and application runtime configuration. It must
  consume platform outputs and must not create a second database, bucket or
  platform-service lifecycle.
- Terraform modules live under their owning Stack (`platform-gcp/modules` or
  `app-gcp/modules`). Do not add a shared `terraform/modules` directory. Small
  data-only helpers are duplicated when necessary so ownership, provider
  configuration and state boundaries remain local to each Stack.
- A new Stack is justified only by an independently approved lifecycle and
  state boundary. It must not recreate or partially claim a resource already
  owned by another Stack.

For Temporal this means extending the existing `platform-gcp` Cloud SQL and
storage modules, then composing the official chart inside `platform-gcp`.
Creating `components/temporal`, `temporal-storage` or a second Cloud SQL/GCS
module outside the owning Stack violates this rule.

The six custom Go workloads are delivered by Cloud Deploy using immutable
digests. `helm/yourown-chat` owns the persistent client-facing application;
`helm/agent-platform` owns only the two pausable workers. A normal pause scales
agent workers to zero while retaining identity data, the server, Temporal
history and reports. Server and agent compute have independent releases; the
agent release still requires a matching server contract tag.

## First safe slice

The pilot builds a plan, waits for an explicit human decision, executes an
idempotent dry-run activity without external side effects and returns a
structured report. Mattermost/Jira adapters, MCP calls, model routing and real
mutations are added one activity at a time after this durable approval path is
verified.

ClickHouse, a separate vector database and Langfuse are deliberately excluded
until measured event volume proves Cloud SQL and standard logs insufficient.
