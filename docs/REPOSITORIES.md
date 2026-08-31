# YourOwn.Chat repository catalog

This public catalog is the source of truth for repository ownership and release
boundaries. It intentionally contains no credentials, private endpoints or
operator identities.

## Product and platform repositories

| Repository | Owns | Must not own | Canonical lifecycle |
|---|---|---|---|
| `pilprod/yourown-chat` | Public architecture, Terraform Stacks, Helm/Skaffold delivery, shared Dockerfiles and release runbooks | Mattermost, MCP, backend or agent application source | `main`; immutable `MAJOR.MINOR.PATCH` platform tags |
| `pilprod/yourown-chat-mattermost` | Reproducible product image assembly and pinned Mattermost/web submodules | Server or web feature development | `main`; `X.Y.Z` dev-preview branches; `X.Y.Z-suffix` prereleases; stable `X.Y.Z` tags |
| `pilprod/mattermost` | Patched public Mattermost Team Edition server fork | Web client, platform IaC or enterprise source | `public-patched` plus immutable `public-patched-X.Y.Z`; `vX.Y.Z-patched` source tags |
| `pilprod/yourown-chat-web` | Standalone web client source and tests | Server code or image release orchestration | `X.Y.Z` version branches; `X.Y.Z-suffix` prereleases and stable `X.Y.Z` tags matching the assembly version |
| `pilprod/yourown-chat-mobile` | iOS/Android client source and client-specific CI | Backend or platform resources | `main`; client release tags follow the client store lifecycle |
| `pilprod/yourown-chat-desktop` | Desktop client source and desktop packaging CI | Backend or platform resources | `master`; desktop release tags follow its upstream-compatible lifecycle |
| `pilprod/yourown-chat-server` | Go microservices for independent user identity, Mattermost workspace links, agent management, approvals, reports and the client-facing Temporal projection | Temporal activity implementation, MCP servers or IaC | `main` CI; immutable `MAJOR.MINOR.PATCH` image tags |
| `pilprod/yourown-chat-agents` | Declarative agent definitions, local-host adapters and agent integration code | Temporal workflow ownership, user-facing control API or IaC | `main` CI; agent-runtime releases are independent of server tags |
| `pilprod/yourown-chat-workflows` | Temporal workflows, activities, deterministic orchestration and replay tests | Local host enrollment, user-facing APIs or IaC | Independent workflow lifecycle |
| `pilprod/yourown-chat-mcp` | First-party Go MCP server source and protocol tests | Platform Terraform/Helm or agent workers | `main` CI; immutable `MAJOR.MINOR.PATCH` MCP releases |
| `pilprod/yourown-chat-rtcd` | Patched RTCD fork and its independent image build | Mattermost server or platform manifests | patched upstream branch; immutable `vX.Y.Z-patched` image tags |
| `pilprod/yourown-chat-migration` | Explicit data/schema migration tooling that cannot live in an owning application repository | Long-running services or shared IaC | `main`; versioned only when a migration artifact is released |

## Build ownership

Application repositories own source, unit tests and language-specific metadata.
`yourown-chat` owns the Cloud Build resources, identities, vulnerability gates,
artifact routing and Cloud Deploy manifests. The platform may provide a shared
Dockerfile, but it never copies application source into this repository.

The Mattermost product is the exception only in shape, not ownership:
`yourown-chat-mattermost` is an assembly repository whose two submodule pointers
select the exact server and web inputs. Its image records three independent
revisions:

1. `pilprod/mattermost` as the AGPL Corresponding Source and server build hash;
2. `pilprod/yourown-chat-web` as the web asset source;
3. `pilprod/yourown-chat-mattermost` as the assembly recipe revision.

## Release invariants

- A tag is immutable after any Cloud Build has observed it.
- First-party sources and the Mattermost assembly use plain
  `MAJOR.MINOR.PATCH`. The assembly additionally accepts prerelease tags such
  as `11.10.0-rc.1`, but routes them only to dev. Maintained upstream forks use
  `vX.Y.Z-patched`.
- `main` builds verify commit-addressed artifacts and do not deploy.
- A release build runs tests, emits SBOM and provenance, scans the digest and
  blocks on High or Critical findings before creating Cloud Deploy state.
- A Mattermost assembly release is valid only when the web commit has the same
  `X.Y.Z[-suffix]` tag and the server commit has
  `vX.Y.Z[-suffix]-patched`.
- A server tag independently releases `auth-api`, `identity-api`,
  `identity-admin`, `identity-migrate` and `control-api`.
- kagent/Substrate artifacts and declarative agents have independent immutable
  releases; Temporal workflows use their own repository and lifecycle.
- Mattermost preview branches are structurally limited to the dev-only pipeline;
  only an accepted assembly tag can enter dev-to-production promotion.

## Branch, tag and submodule selection

A Git submodule always records a commit SHA. The optional `branch` entry in
`.gitmodules` is only a maintainer hint for `git submodule update --remote`; it
must never select release input dynamically. Before tagging an owning
repository, update each gitlink in a normal reviewed commit and tag that owning
repository only after the commit is merged to its canonical branch.

| Input | Development line | Release selection |
|---|---|---|
| `yourown-chat-mattermost/.sources/mattermost` | `release-X.Y-patched` | Exact reviewed SHA from that branch; assembly version `X.Y.Z[-suffix]` requires immutable source tag `vX.Y.Z[-suffix]-patched` on the same commit |
| `yourown-chat-mattermost/.sources/web` | `X.Y.Z` | Exact reviewed SHA from that branch; assembly version `X.Y.Z[-suffix]` requires the identical web tag `X.Y.Z[-suffix]` on the same commit |
| `yourown-chat-web/upstream/mattermost` | Upstream supported release branch | Exact upstream SHA selected and reviewed by `yourown-chat-web`; never a moving branch at build time |
| Desktop/mobile upstream submodules | Their documented upstream maintenance branch | Exact upstream SHA committed in the owning client repository before the client tag |

`yourown-chat-server`, `yourown-chat-agents`, `yourown-chat-workflows` and
`yourown-chat-mcp` are not submodules of the public platform repository. They
are independent release units. Before creating an image tag, the release
operator verifies that the clean local `HEAD` equals `origin/main`. A squashed
pull request is tagged at the resulting `main` commit, never at the obsolete
feature-branch commit. Cloud Build receives configured private source through
the Gen2 connector; no second GitHub credential is copied into build steps.

## Dependency direction

```text
mattermost + yourown-chat-web
             -> yourown-chat-mattermost assembly
             -> Artifact Registry digest
             -> yourown-chat Helm/Skaffold delivery

yourown-chat-server + yourown-chat-mcp
             -> independent tested/scanned image digests
             -> application delivery

kagent + substrate + yourown-chat-agents
             -> immutable control plane and declarative agents
             -> per-agent namespaces and enrolled local hosts

yourown-chat-workflows
             -> independent Temporal workflow lifecycle

platform-gcp (stateful infrastructure)
             -> app-gcp (delivery, secrets, workloads)
```

Repository-specific `AGENTS.md` and architecture documents refine these rules;
they may make a boundary stricter but must not reverse this dependency direction.
