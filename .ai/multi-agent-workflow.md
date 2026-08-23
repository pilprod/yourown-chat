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

