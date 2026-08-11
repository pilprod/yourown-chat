# YourOwn.Chat repository catalog

This public catalog is the source of truth for repository ownership and release
boundaries. It intentionally contains no credentials, private endpoints or
operator identities.

## Product and platform repositories

| Repository | Owns | Must not own | Canonical lifecycle |
|---|---|---|---|
| `pilprod/yourown-chat` | Public architecture, Terraform Stacks, Helm/Skaffold delivery, shared Dockerfiles and release runbooks | Mattermost, MCP, backend or agent application source | `main`; immutable `MAJOR.MINOR.PATCH` platform tags |
| `pilprod/yourown-chat-mattermost` | Reproducible product image assembly and pinned Mattermost/web submodules | Server or web feature development | `main`; `release-X.Y` dev previews; `X.Y.Z-suffix` prereleases; stable `X.Y.Z` releases |
| `pilprod/mattermost` | Patched public Mattermost Team Edition server fork | Web client, platform IaC or enterprise source | `public-patched` plus immutable `public-patched-X.Y.Z`; `vX.Y.Z-patched` source tags |
| `pilprod/yourown-chat-web` | Standalone web client source and tests | Server code or image release orchestration | `main`; revision is pinned by the assembly repository |
| `pilprod/yourown-chat-mobile` | iOS/Android client source and client-specific CI | Backend or platform resources | `main`; client release tags follow the client store lifecycle |
| `pilprod/yourown-chat-desktop` | Desktop client source and desktop packaging CI | Backend or platform resources | `master`; desktop release tags follow its upstream-compatible lifecycle |
| `pilprod/yourown-chat-server` | Go control API: agent management, approvals, reports and the client-facing Temporal projection | Temporal activity implementation, MCP servers or IaC | `main` CI; immutable `MAJOR.MINOR.PATCH` image tags |
| `pilprod/yourown-chat-agents` | Go Temporal workflows, activities, tools and agent compute | User-facing control API, MCP servers or IaC | `main` CI; same immutable `MAJOR.MINOR.PATCH` as server for a coordinated release |
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
  as `11.9.0-rc.1`, but routes them only to dev. Maintained upstream forks use
  `vX.Y.Z-patched`.
- `main` builds verify commit-addressed artifacts and do not deploy.
- A release build runs tests, emits SBOM and provenance, scans the digest and
  blocks on High or Critical findings before creating Cloud Deploy state.
- Server and agents are independently built but only the matching tag set is
  eligible for one coordinated workload release.
- Mattermost preview branches are structurally limited to the dev-only pipeline;
  only an accepted assembly tag can enter dev-to-production promotion.

## Dependency direction

```text
mattermost + yourown-chat-web
             -> yourown-chat-mattermost assembly
             -> Artifact Registry digest
             -> yourown-chat Helm/Skaffold delivery

yourown-chat-server + yourown-chat-agents + yourown-chat-mcp
             -> independent tested/scanned image digests
             -> yourown-chat coordinated delivery

platform-gcp (stateful infrastructure)
             -> app-gcp (delivery, secrets, workloads)
```

Repository-specific `AGENTS.md` and architecture documents refine these rules;
they may make a boundary stricter but must not reverse this dependency direction.
