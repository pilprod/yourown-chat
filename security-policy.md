# Security policy

## Secrets and sensitive values

Agents operate on secret identifiers, access policies, and runtime references
rather than secret values. An agent must not request, retrieve, print, copy,
persist, or transmit a secret value unless a narrowly scoped task explicitly
requires access to that value and the user explicitly authorizes it.

Secret values must not be placed in source code, prompts, task claims, Issues,
pull requests, logs, screenshots, fixtures, generated documentation, build
arguments, image layers, or local files.

Secrets are generated, stored, and injected through the approved secret control
plane. Terraform outputs and operational evidence must expose only secret
identifiers and metadata, not values.

If a secret is unexpectedly exposed, the agent must stop propagating it, avoid
repeating the value, report the affected secret by identifier, and request an
authorized rotation. The agent must not rotate or replace the secret without
explicit authorization.

A private repository is not a secret store. The same restrictions apply to
private rules, coordination Issues, handoffs, and repository-specific policy
overlays.

