# Testing and verification policy

Every change must be verified in proportion to its risk. Verification starts
with the narrowest relevant tests and continues through the repository's
authoritative CI and delivery gates when applicable.

A behavior change requires tests for the new behavior. A bug fix requires a
regression test that fails without the fix. A cross-repository contract change
requires compatibility verification for every affected consumer.

An agent may report a check as passed only when it ran successfully against the
exact revision being handed off. Failed, skipped, unavailable, or incomplete
checks must be reported explicitly.

Tests, security scans, vulnerability gates, coverage requirements, and
deployment verification must not be removed, weakened, bypassed, or marked
optional merely to make a change pass. Such a change requires separate user
approval.

Tests and fixtures must not use production secrets, copied production data, or
sensitive user content.

For an application release, verification includes the authoritative build and
security gates, development deployment verification, explicit production
approval, and production verification defined by the delivery lifecycle. If a
required remote MCP or CI capability is unavailable, the affected check is
reported as not verified rather than inferred from local state.

