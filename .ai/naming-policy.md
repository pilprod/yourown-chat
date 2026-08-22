# Naming policy

## Repositories

First-party product repositories use `yourown-chat` or
`yourown-chat-<bounded-domain>`. A maintained upstream fork retains the
upstream project name without the `yourown-chat-` prefix.

An assembly or integration repository owned by the product uses the
`yourown-chat-` prefix even when it assembles upstream-derived sources.

Repository names describe stable ownership boundaries. They do not encode an
implementation language, cloud provider, environment, team name, temporary
migration phase, or deployment status.

A repository rename requires an approved migration of Git remotes, source
connections, build triggers, submodules, source locks, documentation, and
provenance references. The previous repository is archived or made read-only
after verification rather than silently reused.

