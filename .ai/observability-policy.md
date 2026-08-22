# Observability and audit policy

Every production service exposes health and readiness signals, structured
logs, and the metrics required to verify its documented responsibility.

Every security-relevant or state-changing operation produces an auditable
event containing the attributable actor, tenant or scope, action, target
identifier, approval reference when required, result, correlation identifier,
and timestamp.

Logs and audit events contain identifiers and metadata rather than secret
values, credentials, full request or response bodies, model context, sensitive
tool arguments, or private user content.

Access to sensitive logs is a separate least-privilege capability. General
read-only access to a service or environment does not grant access to its
sensitive logs.

Temporary verbose or debug logging in a remote environment requires explicit
authorization, a bounded duration, and verification that it has been disabled
after use.

Where a request crosses services, workflows, or MCP boundaries, correlation
metadata must allow an authorized operator to follow the operation without
exposing its sensitive payload.

