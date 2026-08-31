# Agent platform architecture

This document is the repository-boundary and runtime contract for the
YourOwn.Chat agent platform. Build and release ownership is defined in
[AGENT_PLATFORM_BUILD_RELEASE.md](AGENT_PLATFORM_BUILD_RELEASE.md).

## Repository boundaries

| Repository | Owns | Must not own |
|---|---|---|
| [`pilprod/yourown-chat`](https://github.com/pilprod/yourown-chat) | Public architecture, Terraform, Helm, immutable pins and delivery routing | Product backend, agent or workflow source |
| [`pilprod/yourown-chat-server`](https://github.com/pilprod/yourown-chat-server) | Client-facing identity, workspace links, agent management, approvals and state projection | Agent execution, workflows or MCP implementations |
| [`pilprod/yourown-chat-agents`](https://github.com/pilprod/yourown-chat-agents) | Declarative agent definitions, local-host adapters and agent integration code | Temporal workflow ownership or platform infrastructure |
| `pilprod/yourown-chat-workflows` | Temporal workflows, activities, deterministic orchestration and replay tests | Local host enrollment or infrastructure ownership |
| [`pilprod/yourown-chat-mcp`](https://github.com/pilprod/yourown-chat-mcp) | First-party MCP servers and protocol/tool tests | Terraform, Helm or workflow state |
| [`pilprod/kagent`](https://github.com/pilprod/kagent) | kagent integration fork and upstreamable control-plane changes | Local Codex or Claude execution |
| [`pilprod/substrate`](https://github.com/pilprod/substrate) | External host enrollment, connectivity and local process/container substrate | Durable workflow orchestration |

## Runtime boundaries

```text
YourOwn.Chat / Temporal
        -> kagent control plane in GKE
        -> Substrate connection and policy
        -> enrolled external host
        -> Codex or Claude process/container
        -> explicitly declared local tools, MCP, skills and memory
```

kagent is the cluster-side control plane. It owns declarative agent lifecycle,
desired state and controller reconciliation. Substrate owns authenticated
connectivity to an enrolled external host. The host launches the requested
runtime as a process or container and exposes only the declared local
capabilities. Temporal, when used, talks to kagent rather than bypassing it to
call the client host directly.

Temporal workflows are a separate durable orchestration layer. They are not a
prerequisite for testing a locally launched agent, and their source and release
lifecycle do not share the kagent/Substrate delivery rail.

## Namespace and authorization boundary

The control plane lives in `kagent-system`. Agent workloads are not placed in
one common namespace. `app-gcp` declares a stable agent-key-to-namespace map;
the initial mapping is `codex -> agent-codex`.

Every declared agent namespace has:

- restricted Pod Security admission labels;
- default-deny ingress and egress;
- an explicit DNS egress baseline;
- a reviewed quota profile;
- the exact namespace-scoped kagent getter, writer and environment-source
  bindings required by the controller.

New namespace resources use functional names without a product prefix. The
existing `yourown.chat/*` ownership and policy label domain remains unchanged.
Controller watch and RBAC scope must be extended only by adding a reviewed map
entry; wildcard namespace access is not an acceptable shortcut.

## Identity and network boundaries

- External hosts authenticate as dedicated host/agent identities, never as the
  interactive user.
- kagent remains the only cluster-side management entry point for Temporal and
  application callers.
- MCP, skills and memory/RAG attachments are declared as agent capabilities;
  their credentials and network permissions remain independently scoped.
- Process mode can use explicitly allowed local tools. Container mode keeps the
  container runtime as the outer sandbox and receives only declared mounts and
  sockets.
- Risky mutations still require an auditable human decision at the owning
  control or workflow layer.

## Terraform ownership rule

Every durable resource has exactly one Stack owner. `platform-gcp` owns GKE,
Cloud SQL, platform buckets, Workload Identity and official platform services
such as Temporal. `app-gcp` owns kagent/Substrate delivery, application runtime
configuration and the per-agent namespace policy. A feature must extend its
current owner instead of creating a parallel Stack, database, bucket or
identity lifecycle.

The active release and ownership handoff are documented in
[KAGENT_SUBSTRATE_RELEASE.md](KAGENT_SUBSTRATE_RELEASE.md).
