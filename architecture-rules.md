# Architecture and delivery rules

These rules apply across all YourOwn.Chat repositories. The private ownership
map identifies the current owner of each component without changing this
public baseline.

## Authoritative ownership

Every source tree, durable resource, cross-repository contract, and release
lifecycle has exactly one documented authoritative owner. Generated or
compatibility copies may exist, but they are never independent sources of
truth.

## Application delivery lifecycle

Every deployable server-side application service and web-delivered application
artifact must follow an owner-approved dev-to-production delivery pipeline that
promotes the same immutable artifact after development verification and
explicit production approval. Production must not rebuild, replace, or retag
the verified artifact.

Independently deployable components may use separate pipelines and release
schedules, but every pipeline must implement the same dev-to-production
lifecycle contract.

Native iOS, Android, and desktop applications are excluded from the
dev-to-production environment model. They follow separately approved store or
release-channel lifecycles.

Terraform-managed platform services and durable infrastructure follow the
separately approved infrastructure-as-code lifecycle. They are outside the
application delivery lifecycle defined above.

