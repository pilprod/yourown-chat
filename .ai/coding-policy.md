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

## Dependencies

A new or upgraded dependency requires a documented need. Existing project or
standard-platform capabilities are preferred when they satisfy the requirement
without increasing risk.

Before adoption, the dependency is evaluated for source authenticity, license
compatibility, maintenance status, known vulnerabilities, ecosystem
compatibility, and transitive footprint.

Dependency versions and release inputs are pinned according to the
repository's ecosystem. Lock files and checksum files are committed and must
not be edited manually. Moving branches, floating versions, and unreviewed
`latest` references are not release inputs.

A dependency change requires the applicable tests, vulnerability checks, and
license verification before handoff.
