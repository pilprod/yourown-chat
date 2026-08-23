# ADR 0001: Engineering governance and agent coordination

- Status: Superseded
- Date: 2026-08-22
- Superseded: 2026-08-23
- Decision owner: Project owner

## Superseding decision

Shared engineering governance is no longer attached to product repositories.
The former public `.ai/` content is preserved under
`pilprod/yourown-chat-rules/public/` together with the former private rules,
but that repository is inactive and disconnected. Root discovery adapters and
governance submodules are removed from consumers.

## Context

YourOwn.Chat spans multiple source, fork, client, platform, and delivery
repositories. Human and AI-assisted work may occur concurrently. Repeating
rules in task prompts or maintaining independent copies makes instruction
drift, worktree interference, and unsafe release concurrency likely.

The project also needs internal agent procedures without making credentials or
sensitive operating details public.

## Decision

The following records the original decision that was active before the
superseding decision above.

The public `pilprod/yourown-chat` repository owned the universal Engineering
Constitution and multi-agent workflow under `.ai/`. Normative rule files were
written in English.

The private `pilprod/yourown-chat-rules` repository owned private agent policy
overlays and the coordination issue registry. Private policy could tighten but
could not weaken the public baseline. Neither repository stored secrets.

`AGENTS.md` and `CLAUDE.md` were thin discovery adapters. Public rules were
distributed as a pinned rules-only Git submodule. Private rules were installed
locally as an ignored, revision-locked overlay so public clones did not require
private credentials.

Every mandatory rule and architectural policy change required explicit owner
approval before it became normative.

## Original consequences

These consequences described the superseded model and no longer define current
repository behavior:

- Agents could discover one public baseline from every repository.
- Public builds and contributors remained independent of private Git access.
- Private operational procedures remained versioned and auditable.
- Rule changes and repository adoption happened through reviewable commits.
- Each repository was expected to add the approved adapters and pinned public
  rules delivery mechanism.
