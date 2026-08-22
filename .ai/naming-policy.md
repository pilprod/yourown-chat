# Naming policy

## Repositories

First-party product repositories use `yourown-chat` or
`yourown-chat-<bounded-domain>`. A maintained upstream fork retains the
upstream project name without the `yourown-chat-` prefix.

An assembly or integration repository owned by the product uses the
`yourown-chat-` prefix even when it assembles upstream-derived sources.

Repository names describe stable ownership boundaries. They do not encode an
implementation language, cloud provider, environment, team name, temporary
migration phase, or deployment status.

A repository rename requires an approved migration of Git remotes, source
connections, build triggers, submodules, source locks, documentation, and
provenance references. The previous repository is archived or made read-only
after verification rather than silently reused.

## Resources

Externally visible resource names use lowercase ASCII kebab-case. The stable
component or domain comes first, followed by the resource role. An environment
or qualifier is added only when it is required to distinguish resources within
the same authoritative scope.

A resource name does not repeat information already guaranteed by its parent
scope. Product, environment, region, provider, or project prefixes are not
repeated when the project, Stack, namespace, repository, or registry already
provides that boundary.

Names describe stable responsibility rather than implementation language,
current team, temporary migration state, deployment status, or incidental
technology.

Terraform block labels and local identifiers use descriptive `snake_case`.
Remote resource names use the provider-appropriate form, normally kebab-case.
Names and abbreviations remain consistent across source, CI, deployment,
observability, and documentation.

The default external resource form is:

```text
<component>[-<role>][-<environment>][-<qualifier>]
```

An environment token is omitted when an authoritative namespace, Stack, or
equivalent parent scope already identifies the environment.

The approved common abbreviations are `api`, `ci`, `cd`, `gke`, `iam`, `kms`,
`mcp`, `rtcd`, `sql`, and `ui`. A new abbreviation is defined before it is
introduced across resources.

A resource rename is a lifecycle change, not cosmetic cleanup. It requires
impact review because it may recreate infrastructure, break references, or
lose history.
