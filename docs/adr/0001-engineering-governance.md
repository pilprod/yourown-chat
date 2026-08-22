# ADR 0001: Engineering governance and agent coordination

- Status: Accepted
- Date: 2026-08-22
- Decision owner: Project owner

## Context

YourOwn.Chat spans multiple source, fork, client, platform, and delivery
repositories. Human and AI-assisted work may occur concurrently. Repeating
rules in task prompts or maintaining independent copies makes instruction
drift, worktree interference, and unsafe release concurrency likely.

The project also needs internal agent procedures without making credentials or
sensitive operating details public.

## Decision

The public `pilprod/yourown-chat` repository owns the universal Engineering
Constitution and multi-agent workflow under `.ai/`. Normative rule files are
written in English.

The private `pilprod/yourown-chat-rules` repository owns private agent policy
overlays and the coordination issue registry. Private policy may tighten but
cannot weaken the public baseline. Neither repository stores secrets.

`AGENTS.md` and `CLAUDE.md` are thin discovery adapters. Public rules are
distributed as a pinned rules-only Git submodule. Private rules are installed
locally as an ignored, revision-locked overlay so public clones do not require
private credentials.

Every mandatory rule and architectural policy change requires explicit owner
approval before it becomes normative.

## Consequences

- Agents can discover one public baseline from every repository.
- Public builds and contributors remain independent of private Git access.
- Private operational procedures remain versioned and auditable.
- Rule changes and repository adoption happen through reviewable commits.
- Each repository must eventually add the approved adapters and pinned public
  rules delivery mechanism.

