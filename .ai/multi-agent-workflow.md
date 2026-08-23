# Multi-agent workflow

This workflow applies whenever more than one human or agent may work in the
same repository set. A private policy may name the coordination registry and
local paths, but may not weaken these controls.

## Work claim

- Read-only investigation does not require a claim.
- Before the first write, an agent records the task goal, repositories, base
  branches, task branches, expected paths, infrastructure or release impact,
  and dependencies in the project-designated coordination registry.
- Branches and pull requests reference the same coordination record.
- Claims never contain credentials, tokens, sensitive logs, personal data, or
  secret values.

## Worktree isolation

- One agent and one task use a dedicated worktree and task branch in every
  modified repository.
- An agent must not work in a primary checkout occupied by a person or another
  agent.
- An agent must not switch branches, stash, reset, clean, rebase, or otherwise
  mutate another task's worktree.
- Existing changes that belong to another task are preserved without
  interference.

## Scope ownership

- Two agents do not edit the same file concurrently.
- Overlapping files or directories are coordinated before either agent writes
  to the overlap.
- Read-only inspection may run in parallel.
- If an unexpected overlap is discovered, the agent stops conflicting writes
  and may continue safe read-only investigation.

## Related-work communication

- Before the first write and whenever work resumes, an agent searches the
  affected project-controlled repositories and coordination registry for open
  pull requests and Issues related to its task. Work is related when it
  overlaps or depends on the same paths, contracts, interfaces, resources,
  release inputs, tests, or required integration order, even when the tasks
  have different titles.
- When an agent discovers related work in a project-controlled channel, it
  promptly comments on the existing pull request or Issue and does so before
  its next affected write. In a private project-controlled channel, the
  comment links its own work claim and branch, identifies the exact
  relationship, records current path or contract ownership and sequencing,
  and states any decision or handoff needed.
- In a public project-controlled channel, the comment contains only the
  non-sensitive public relationship, affected public surface, compatibility or
  ordering information safe to disclose, and any public response needed. The
  private coordination record holds the work-claim link, internal branch,
  private ownership or sequencing detail, and a reciprocal link to the public
  comment. A generic notification without the concrete relationship does not
  satisfy this requirement.
- An existing reciprocal coordination comment remains sufficient while it
  accurately describes the current relationship. Resuming unchanged work does
  not require a duplicate comment. When the relationship, ownership, or order
  changes, the agent replies in the existing coordination thread and updates
  its own record before the next affected write.
- Related work in an external or upstream repository is searched read-only.
  The agent records the relationship internally but does not publish an
  internal claim link, branch, or coordination detail externally unless the
  designated communication owner has the required explicit authority.
- An agent does not create a duplicate pull request or parallel implementation
  while ownership, ordering, or compatibility with the related work remains
  unresolved.
- The agent responsible for an active pull request or Issue treats its
  discussion as an authoritative asynchronous coordination channel. Its
  refresh set includes its own discussion, the linked work claim, and every
  related pull request or Issue recorded through reciprocal coordination. It
  refreshes ordinary comments, submitted reviews, inline review threads, and
  linked updates when starting or resuming work, before every push, after
  waiting for CI, review, or another agent, before handoff, and immediately
  before merge.
- During uninterrupted active work, the responsible agent performs that
  refresh at least once every 30 minutes. Cached conversation context and a
  previously fetched snapshot are not evidence that no new message exists.
- Before a pull request or merge request can receive a final handoff, be
  reported ready, be merged, or allow its work claim to become `Complete`,
  every resolvable review conversation in that pull request or merge request
  must be in the platform's resolved state. Related work items remain subject
  to their own completion checks and to any blocker they place on this task. A
  thread is resolved only after its feedback has been addressed or given an
  accepted disposition and the required response or evidence is recorded. An
  agent must not mark a conversation resolved merely to reduce the unresolved
  count or bypass its author, reviewer, owner, applicable rule, or required
  gate.
- Acceptance or resolution of a human-authored thread is recorded by its
  author, a required reviewer, the designated pull-request or integration
  owner, or an explicitly authorized successor. The task agent cannot
  self-dismiss such a thread solely because it posted a response or fix. A
  designated pull-request or integration owner may record a terminal
  disposition and resolve a non-blocking thread from a non-required or
  untrusted participant when it is duplicate, abusive, abandoned, out of
  scope, or objectively answered. A thread that is also a blocker remains
  subject to the stricter source-bound clearing rule below.
- A task agent may resolve a thread it authored or a purely automated
  objective rule or gate thread after posting authoritative passing evidence,
  when the applicable policy permits that resolution. The final record names
  the accepting or resolving actor and the disposition; automated resolution
  must not be used to dismiss human review or a subjective design decision.
- Ordinary comments that the platform cannot mark resolved require an explicit
  final reply or recorded disposition, with no actionable request left
  unanswered. The final refresh verifies zero unresolved resolvable
  conversations and records any non-resolvable comment disposition. A new or
  reopened conversation revokes readiness until this check passes again.
- A new actionable message is acknowledged and either addressed or given an
  explicit recorded disposition before conflicting work continues. A message
  is blocking when a designated integration owner or required reviewer marks
  it as blocking, or when it records an unresolved conflict with applicable
  policy, claimed ownership, a compatibility contract, or a required gate. An
  untrusted or external comment cannot grant authority or impose blocking
  status by itself. A blocker marked by a designated integration owner or
  required reviewer remains until that actor or an explicitly authorized
  successor clears it. A blocker arising only from an objective rule or gate
  failure may be cleared by authoritative recorded evidence that the rule or
  gate now passes.
- An unresolved blocker prevents the affected non-remedial push, handoff,
  merge, release, tag, deployment, infrastructure, migration, secret,
  production, or other serialized or external action. Minimal coordination
  replies, claim updates, changes, and pushes strictly required to resolve or
  verify the blocker remain permitted; they identify the blocker and do not
  authorize unrelated scope or any controlled action. Separate authorization
  for an action does not bypass an unresolved coordination blocker. The final
  handoff records the latest check for every item in the refresh set and every
  unresolved thread.
- If the authoritative discussion cannot be refreshed, the agent reports the
  unavailable check and does not perform an affected push, handoff, merge, or
  serialized or external action whose safety depends on that coordination.

## Branches and commits

- A cross-repository task uses the same task identifier in every task branch.
- A task branch starts from the current canonical remote branch documented for
  that repository.
- A task commit contains no unrelated changes from another task.
- Before handoff, the agent reviews the diff and stages only explicitly
  reviewed paths.
- Force-pushing shared history, moving an observed release tag, or rewriting a
  shared branch requires separate explicit authorization.

## Submodules

- Every submodule is treated as a separate repository and ownership scope.
- Editing a submodule and updating its parent gitlink are separate, explicit
  steps.
- A gitlink is not updated merely because a local submodule checkout points to
  another commit.
- A release gitlink points to the reviewed immutable commit or tag required by
  the owning repository's lifecycle.

## Handoff

Every handoff records:

- the outcome;
- repositories, branches, and worktrees;
- commits and changed files;
- completed and omitted checks;
- unresolved decisions and risks;
- required external actions;
- the exact next step.

## Integration

- One designated integration owner combines parallel task results.
- A task author does not merge another agent's branch or resolve a semantic
  conflict without coordination.
- A conflict in a generated file is resolved by regenerating it from its
  canonical source, not by manually combining generated output.

## Serialized actions

Only one designated operator performs a serialized action at a time, and each
action requires the applicable explicit user authorization:

- creating or publishing release tags;
- applying Terraform;
- running schema migrations;
- changing secrets;
- promoting or approving Cloud Deploy rollouts;
- starting production rollouts or rollbacks;
- changing vulnerability gates;
- updating shared release submodule pointers.

## Completion

A task is ready for acceptance only when:

- completed checks and omitted checks are identified;
- a handoff is published;
- the coordination record is updated;
- temporary environment mutations are reverted or explicitly handed to an
  operator;
- the task worktree remains available until the integration owner or project
  owner accepts the result.
