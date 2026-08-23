# kagent: подключение fork и релизный процесс

## Решение

`pilprod/kagent` — upstream-first fork. `yourown-chat` не копирует его исходники,
а хранит проверяемый release BOM, устанавливает зафиксированные OCI charts и
используется как общий system testbed.

Fork и `yourown-chat` выпускаются независимо. Версия пользовательского сервера
или Temporal workers не выбирает версию kagent автоматически.

Канонический состав текущего baseline находится в
[`helm/kagent/release.lock`](../helm/kagent/release.lock).

## Текущий этап M0

Первый baseline — официальный `v0.9.12`, который также присутствует в fork без
наших патчей. Он нужен только для подключения и построения сквозных тестов.

Статус: `bootstrap-unqualified`.

Ограничения M0:

- отдельные namespace `kagent-system` и `kagent-testbed`;
- `kagent-crds` устанавливается раньше `kagent`;
- controller видит только эти два namespace;
- UI, встроенные агенты, tools, KMCP и Substrate выключены;
- модель заменяется детерминированным test fixture;
- bundled PostgreSQL допустим только в testbed;
- API остаётся `ClusterIP` и закрыт ingress NetworkPolicy;
- Terraform gate `kagent_testbed_enabled` выключен по умолчанию.

Это не production profile. В `v0.9.12` нет нужной нам authorization boundary, а
Helm templates controller/UI формируют `repository:tag` и не принимают
`image.digest`.

## Артефакты и источник истины

Для каждого baseline или fork candidate фиксируются:

- fork и upstream repository;
- upstream tag и полный source commit;
- patch-set digest;
- версии `kagent-crds` и `kagent`;
- OCI manifest digest обоих charts;
- SHA-256 скачанных chart archives;
- qualification status.

Terraform дублирует только значения, необходимые для установки. Тест
`helm/test/kagent-release.test.sh` блокирует расхождение с `release.lock`.

## Локальная проверка baseline

Без сети проверяются release lock и Terraform wiring:

```bash
bash helm/test/kagent-release.test.sh
```

Полная проверка скачивает exact chart version, сверяет archive SHA-256 и
рендерит оба release:

```bash
KAGENT_VERIFY_REMOTE=1 bash helm/test/kagent-release.test.sh
```

При уже скачанных chart:

```bash
KAGENT_CHART_CACHE=/path/to/charts bash helm/test/kagent-release.test.sh
```

Перед включением testbed:

```bash
terraform stacks -chdir=terraform/app-gcp validate
bash helm/test/kagent-release.test.sh
```

После проверки плана `kagent_testbed_enabled` можно изменить на `true` одним
отдельным review. Этот toggle не запускает Temporal workers.

## Выпуск fork candidate

Fork tag имеет собственную нумерацию, например
`v0.10.0-rc3.kap.1`. Перед первым tag workflow fork необходимо исправить так,
чтобы он публиковал в `ghcr.io/pilprod/kagent`, не пытался писать в namespace
upstream и не зависел от отсутствующего PyPI token.

Один candidate build обязан:

1. Запустить неизменённые upstream unit, Helm, Kind E2E, migration и upgrade
   checks.
2. Проверить patch ledger: у каждого fork commit есть upstream issue/PR,
   regression test, owner и условие удаления.
3. Один раз собрать controller, используемый runtime и, только если нужен, UI.
4. Опубликовать `kagent-crds` и `kagent` в OCI fork.
5. Зафиксировать image/chart digests, SBOM и provenance.
6. Просканировать каждый поставляемый образ. High или Critical блокируют
   candidate без явно оформленного waiver.
7. Обновить `release.lock` отдельным PR в `yourown-chat`.

Нельзя публиковать candidate из произвольного `workflow_dispatch` без связи с
reviewed commit и release evidence.

## Qualification в yourown-chat

Candidate проходит последовательно:

1. Чистая установка CRD и controller.
2. Создание агента и A2A Task через platform connector.
3. Stream, reconnect, `GetTask`, cancel и terminal result без потерь.
4. Повтор Temporal Activity с тем же idempotency key без второй Task.
5. Read-only MCP invocation через `RemoteMCPServer`.
6. Разделение двух пользователей без утечки task, memory или credential.
7. Restart controller и worker во время выполнения.
8. Upgrade с предыдущего baseline и rollback drill.
9. Три последовательных чистых deterministic прогона и 24-часовой soak.

Реальные model providers запускаются отдельным opt-in smoke. Они не заменяют
детерминированный release gate.

## Promotion

Каналы:

| Канал | Назначение | Production target |
| --- | --- | --- |
| `testbed` | Первое подключение и воспроизведение upstream gaps | Нет |
| `preview` | Проверка fork candidate в общей системе | Нет |
| `stable` | Поддерживаемый состав K8s Agents Platform | Только после approval |

Promotion не пересобирает artifacts. В stable переходят те же image и chart
digests, которые прошли preview.

Production promotion остаётся заблокирован, пока не выполнены одновременно:

- chart поддерживает digest-native controller/runtime images;
- authentication проверяет подпись, authorization работает fail-closed;
- используется внешний PostgreSQL с проверенным backup/restore;
- CRD и DB migrations имеют upgrade/rollback evidence;
- прямой runtime egress к mutating MCP provider закрыт;
- отсутствуют открытые P0/P1 для включённого профиля.

## Rollback

Откат выполняется на предыдущий release BOM, а не на mutable tag. Helm rollback
сам по себе не восстанавливает PostgreSQL и не откатывает безопасно CRD storage
version. Поэтому первый stable допускает только in-place-compatible изменения:

- expand/contract DB migration;
- неизменная CRD storage version;
- предыдущие images и charts сохранены;
- старые Task читаются после rollback;
- незавершённый вызов не повторяет побочный эффект.

После принятия нашего PR upstream соответствующий patch удаляется из fork, его
ledger entry получает статус `drop-next-rebase`, а candidate проходит полную
квалификацию повторно.

## Upstream workflow

Для крупной функции сначала открывается upstream issue и согласуется план,
затем ранний draft PR. Каждый commit подписывается DCO, а изменение поведения
сопровождается E2E. См. официальный
[`CONTRIBUTING.md`](https://github.com/kagent-dev/kagent/blob/main/CONTRIBUTING.md).
