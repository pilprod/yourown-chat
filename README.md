# YourOwn.Chat engineering governance

This directory is the canonical public source for universal engineering rules
across YourOwn.Chat repositories.

## Required reading

Before making a change, read:

1. [Engineering Constitution](engineering-constitution.md)
2. [Architecture and delivery rules](architecture-rules.md)
3. [Infrastructure-as-code policy](infrastructure-policy.md)
4. [Security policy](security-policy.md)
5. [Testing and verification policy](testing-policy.md)
6. [Tool use policy](tool-use-policy.md)
7. [Multi-agent workflow](multi-agent-workflow.md)
8. The applicable repository-specific architecture and contributor documents

Internal agents may also receive a private policy overlay. A private overlay
may add or tighten controls, but it cannot weaken or contradict the public
Constitution.

## Sources of policy

- Files in this directory are the public source of truth.
- `AGENTS.md` and `CLAUDE.md` are discovery adapters, not independent policy
  documents.
- Generated copies and exported branches are delivery artifacts. They must not
  be edited as independent sources.
- Architecture Decision Records explain accepted decisions but do not override
  the Constitution.

All normative rule documents are written in English. Agents may communicate
with users in the user's preferred language.
