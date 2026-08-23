# YourOwn.Chat Engineering Constitution

Status: Accepted baseline  
Owner: Project owner  
Canonical location: `pilprod/yourown-chat/.ai/engineering-constitution.md`

## Purpose

This Constitution defines the universal public governance baseline for human
and AI-assisted engineering across YourOwn.Chat repositories. It contains only
rules explicitly approved by the project owner.

## Instruction precedence

1. External legal, licensing, safety, and platform-enforced controls always
   apply.
2. The user's explicit current instruction takes precedence over repository
   defaults.
3. Production, release, secret, migration, destructive, and otherwise
   irreversible actions require explicit authorization for that specific
   action.
4. This public Engineering Constitution defines the universal project
   baseline.
5. Private agent policies may add or tighten controls, but must not weaken or
   contradict this Constitution.
6. Repository-specific instructions may refine rules only within that
   repository's ownership boundary.
7. Task claims and handoffs may narrow scope but cannot override governance
   rules.
8. `AGENTS.md` and `CLAUDE.md` are adapters, not independent sources of policy.
9. If two applicable instructions conflict, the agent must stop the conflicting
   action and request a user decision.
10. No agent may create, reinterpret, or approve a mandatory project rule on
    the user's behalf.

## Rule approval and change control

- Every new mandatory rule must be proposed to and explicitly approved by the
  project owner before it is added.
- An agent may recommend a rule but cannot make that recommendation binding.
- An approved rule change is recorded as a version-controlled diff and commit.
- An architectural decision is recorded in an Architecture Decision Record
  after owner approval.
- Repository-specific rules may be stricter than the public baseline only
  after owner approval and may not reverse the documented repository
  dependency direction.

## Public and private policy boundary

- Universal architecture, coding, security, testing, delivery, and
  collaboration rules belong in this public governance directory once
  approved.
- Private agent coordination and internal operating procedures belong in the
  private `pilprod/yourown-chat-rules` repository.
- Credentials, tokens, private keys, secret values, sensitive logs, personal
  data, and copied infrastructure state are not policy and must not be stored
  in either rules repository.
- Private policy is an overlay. Access to it is not required to understand the
  public engineering baseline.

## Language

Normative rule files and rule templates are written in English. This language
requirement does not restrict user communication or non-normative translated
documentation.

