# YourOwn.Chat engineering governance

This directory is the canonical public source for universal engineering rules
across YourOwn.Chat repositories.

## Required reading

Before making a change, read:

1. [Engineering Constitution](engineering-constitution.md)
2. [Architecture and delivery rules](architecture-rules.md)
3. [Coding policy](coding-policy.md)
4. [Infrastructure-as-code policy](infrastructure-policy.md)
5. [Helm platform policy](helm-policy.md)
6. [Security policy](security-policy.md)
7. [Licensing and upstream provenance policy](licensing-policy.md)
8. [Naming policy](naming-policy.md)
9. [Observability and audit policy](observability-policy.md)
10. [Release and recovery policy](release-policy.md)
11. [Testing and verification policy](testing-policy.md)
12. [Tool use policy](tool-use-policy.md)
13. [Multi-agent workflow](multi-agent-workflow.md)
14. The applicable repository-specific architecture and contributor documents

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
