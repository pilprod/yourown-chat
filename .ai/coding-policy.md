# Coding policy

## Bounded change scope

An implementation is limited to the approved task scope and the authoritative
owning repositories. It follows the existing architecture and repository
conventions unless an approved decision changes them.

Unrelated refactoring, dependency upgrades, generated-file rewrites,
formatting sweeps, renames, and cleanup must not be mixed into the task merely
because the agent encountered them.

If an additional change is genuinely required to complete the task safely,
the agent must identify it, explain the dependency, and obtain approval for the
expanded scope before implementing it.

