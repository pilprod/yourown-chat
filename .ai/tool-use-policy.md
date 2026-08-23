# Tool use policy

## Approved remote control plane

Agents must access project-managed remote systems only through the approved MCP
integration for that system. Local cloud or infrastructure CLIs, direct
control-plane API calls, and browser or computer-control automation must not be
used as implicit fallbacks.

If the required MCP capability is unavailable, the agent must stop the remote
action, report the missing capability, and request a user decision. It must not
silently fall back to a local CLI, direct API call, cloud console, or
remote-control tool.

Access through MCP does not grant authority by itself. Production, release,
secret, migration, destructive, and otherwise irreversible actions still
require the explicit authorization defined by the Engineering Constitution.

## Local infrastructure tools

- Local `gcloud` and `kubectl` must not be used to inspect or mutate project
  cloud or cluster state.
- A local Docker daemon and local `docker build`, `docker push`, or equivalent
  container publication commands must not be used for project artifacts.
- Local Terraform execution is limited to `terraform fmt -check` and offline
  `terraform validate` when the required providers are already available and
  no backend, provider installation, refresh, plan, or remote operation is
  performed.
- Local `terraform init`, `plan`, `apply`, `destroy`, `import`, `state`, backend
  operations, and provider operations must not be used for project-managed
  infrastructure.

## User-interface automation

Browser, Chrome, computer-control, and remote-control tools may be used for
application user-interface verification. They must not be used to administer
cloud, Terraform, Kubernetes, build, deployment, registry, or vulnerability
control planes, or to bypass an MCP policy or approval.

