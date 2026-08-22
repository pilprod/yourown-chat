# Release and recovery policy

Before production approval, every change identifies the exact immutable
artifact and configuration, compatibility requirements, migration impact,
rollback target, rollback procedure, and post-rollback verification.

A production change must be reversible through the authoritative delivery
system or have an explicitly approved forward-recovery procedure when rollback
is technically unsafe.

Database and durable-state changes use an expand-and-contract migration
strategy and remain compatible with every application version that may run
during rollout or rollback. Destructive migration steps are isolated,
separately authorized, and performed only after the old version can no longer
require the removed data or schema.

Application rollback does not imply data rollback. Backup, restore, forward
repair, and data-loss consequences must be evaluated separately.

Rollback and recovery operations use the authoritative delivery system through
the approved MCP route. They are followed by explicit verification of the
application, data compatibility, and intended environment state.

## Source forks and product releases

Tags in maintained upstream forks are source provenance markers only. They
must not start image publication, a delivery release, an environment rollout,
or a production workflow.

A fork change reaches a release only after its exact reviewed commit is pinned
by the documented release-owning repository and that repository publishes its
own immutable product release tag.

Repository-specific agent instructions identify the release-owning repository,
the pinned input, and the authoritative build and deployment lifecycle. An
agent working in a source fork must not attempt to release from the fork.
