# Agent platform direction

This document records the target architecture; it is not all implemented yet.

## Stable boundaries

- `tools.yourown.chat/mcp` is the shared Cloudflare MCP tool gateway for
  Mattermost, Claude, ChatGPT and future autonomous agents.
- `agents.yourown.chat` is reserved for a future agent control-plane API/UI.
- Mattermost is the human interface: task threads, questions, progress,
  approvals and audit-visible outcomes.
- Temporal is the durable owner of long-running task state, timers, retries,
  cancellation and human waits.
- LangGraph (or an equivalent graph runtime) runs bounded supervisor/subagent
  reasoning inside Temporal activities. LLM and MCP calls never run in
  deterministic Temporal workflow code.
- MCP servers provide tools. They do not own task orchestration or human
  conversation state.

## Planned flow

1. A Jira issue or Mattermost command starts a Temporal workflow.
2. The Mattermost Agent Gateway creates one thread and stores the mapping
   `jira_issue ↔ workflow_id ↔ root_post_id`.
3. A supervisor delegates bounded work to domain agents and a review agent.
4. Agents call tools through the common Cloudflare Portal.
5. Questions and risky actions pause the workflow. A Mattermost reply or
   Approve/Edit/Reject action resumes it through a Temporal Signal.
6. Every action records workflow, issue, thread, agent, human identity, model,
   tool, arguments, decision and result.

## Identity evolution

The first integration uses Cloudflare Portal OAuth for interactive Mattermost
users while upstream MCP registrations retain shared workload credentials
(`on_behalf = false`). This gives a user identity at the Portal boundary but
does not yet propagate it into each adapter.

The autonomous Agent Gateway will receive a separate workload identity. Do not
reuse an interactive user's OAuth grant or the Cloudflare AI Controls upstream
token for background workflows.

The later RBAC phase propagates signed Mattermost identity/claims through the
Gateway and validates user, role, agent and tool policy inside adapters. It
must preserve the public `tools.yourown.chat/mcp` contract.

## Network boundary

Production namespaces are independent tenants. Mattermost can reach public
HTTPS and its exact Cloud SQL address, but no MCP ClusterIP. MCP namespaces
admit only the isolated `mcp-tunnel` connector and cannot initiate traffic to
one another. Matterbridge reaches Mattermost through the public
`https://yourown.chat` edge rather than a cross-namespace Service. The shared
`dev` namespace remains one disposable tenant.
