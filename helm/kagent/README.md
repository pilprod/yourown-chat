# kagent testbed

Этот каталог хранит release lock и безопасный минимальный профиль kagent для
сквозной проверки в `yourown-chat`.

Сам kagent не копируется в этот репозиторий. Terraform устанавливает два
официальных OCI chart в строгом порядке: сначала `kagent-crds`, затем `kagent`.
Исходный fork находится в `pilprod/kagent`, а точная ревизия и digests chart
записаны в `release.lock`.

Профиль является **testbed, а не production release**:

- UI, встроенные агенты, tools, KMCP и Substrate выключены;
- controller видит только `kagent-system` и `kagent-testbed`;
- API не публикуется наружу и ограничивается NetworkPolicy;
- используется bundled PostgreSQL;
- controller и UI upstream chart пока задаются tag, а не image digest;
- `v0.9.12` не обеспечивает требуемую production authorization.

Production promotion закрыта, пока fork/upstream не добавит digest-native image
values, проверяемую authentication/authorization и внешний PostgreSQL.

Проверка локального cache официальных chart:

```bash
KAGENT_CHART_CACHE=/path/to/charts bash helm/test/kagent-release.test.sh
```

Полный процесс обновления и квалификации описан в
[`docs/KAGENT_RELEASE.md`](../../docs/KAGENT_RELEASE.md).
