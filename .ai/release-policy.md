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

