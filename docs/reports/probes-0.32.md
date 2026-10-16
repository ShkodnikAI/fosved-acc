# Пробы Metalogos 0.32.0 (наряд АСС-0, блок B)

Бинарь: `mlog 0.32.0` (релиз `v0.32.0`, SHA256 `dd8164b7…bc59a2` — совпадает с `tega-platform/Dockerfile` и `FOSVED-office-v2/bin/mlog`).
Прогон: `probes/run.sh mlog`, 16.10.2026, локально и в CI (джоба «Probes Metalogos», артефакт `probes-result`).
Документация для сверки: `ShkodnikAI/Metalogos-` на теге `v0.32.0` — `REFERENCE.md`, `docs/newcomer-contract.md`.

| № | Итог | Что проверено | Документ |
|---|---|---|---|
| B.1 schedule | PASS | `cron_add`/`cron_list`/`cron_run`/`cron_mark_fired`/`cron_remove` работают, `tz` и `catch_up` принимаются. **Расхождение с документацией:** `cron_run`, `cron_mark_fired`, `cron_remove` возвращают Struct (`CronRemoveResult {removed, status}`), а REFERENCE §4.17.3 пишет Float. Срабатывание по времени идёт только в `mlog serve` (тик 5 с) — в пробе не проверялось; в FOSVED-office-v2 известна проблема регистрации расписаний при медленном старте (#520) | REFERENCE §4.17.3 |
| B.2 untrusted | PASS | `query_param` без `redact` в условии `if` → отказ `UNTRUSTED_DECISION` при запуске и `[ERROR]` в `mlog audit`; после `redact(…, "all")` исполняется | REFERENCE (метки происхождения), №0.28 |
| B.3 env-route | PASS | в маршруте `mlog serve` без `METALOGOS_ENV_ALLOWLIST` `env()` не читается; с allowlist читается. Попытка вывести значение в `respond` — отказ `PII_EGRESS_OUTPUT` | newcomer-contract (№259) |
| B.4 ssrf | PASS | `127.0.0.1`, `10.0.0.1`, `169.254.169.254` отклонены `SSRF guard`; снимается только `METALOGOS_HTTP_ALLOW_PRIVATE=1` | REFERENCE (HTTP egress, №130/150/261) |
| B.5 grants | PASS | `grant_issue(scope, ttl, "once")`: одно применение, повтор → `GRANT_REUSED`; чужая область → `GRANT_SCOPE_MISMATCH`; истёкший срок → `GRANT_EXPIRED`; `DELETE` без права отклоняется ещё до исполнения (`IRREVERSIBLE_NO_GRANT`) | REFERENCE §4.15.1 |
| B.6 ledger | PASS | действие по праву пишет запись; `ledger_export` + `ledger_verify` → `ok=true`; изменённая запись → `ok=false` («hash mismatch») | REFERENCE (ledger_*), docs/ledger-runbook.md |
| B.7 exec | PASS | `exec_argv` закрыт по умолчанию (`EXEC_NOT_PERMITTED`); `METALOGOS_ALLOW_EXEC=1` открывает в `run`; в маршрутах `serve` — отдельный `METALOGOS_SERVE_ALLOW_EXEC` | newcomer-contract (№253) |
| B.8 mcp-allowlist | PASS | без `METALOGOS_ALLOW_EXEC` MCP закрыт целиком; с ним сервер вне `METALOGOS_MCP_ALLOWLIST` → `MCP_NOT_ALLOWLISTED` | newcomer-contract (№268) |
| B.9 llm-per-provider | **ABSENT** | у провайдера в блоке `llm {}` нет собственной модели: после отказа первого провайдера резерв получил `default_model`. Третий аргумент `call_llm(prompt, input, model)` меняет модель вызова, но не выбирает провайдера; имя алиаса провайдера уходит как литерал модели | REFERENCE §5.11, `call_llm` |
| B.10 llm-timeout | PASS | поле `timeout` в блоке `llm {}` соблюдается: при `timeout: 3` вызов оборван за ~5 с (без поля — 30 с по умолчанию, замер в FOSVED-office-v2 #505) | REFERENCE §5.11 |

## Выводы для АСС

1. Всё, на что ТЗ §12 опирает безопасность, в 0.32.0 есть и работает: недоверенный ввод, запрет `env()` в маршрутах, SSRF, ограниченные права, подписанный журнал, закрытые по умолчанию `exec` и MCP.
2. **Маршрутизатор моделей нельзя сделать одним блоком `llm {}`** (B.9). Варианты для этапа 1:
   - а) свой маршрутизатор АСС поверх `http_post` к OpenAI-совместимым адресам провайдеров из реестра моделей: своя модель у каждого, свой резерв, свой учёт. Минус — теряются кэш, трассировка и учёт, встроенные в `call_llm`;
   - б) запрос в Metalogos: поле `model` у каждого провайдера в блоке `llm {}` (грамматика 0.32.0 его не принимает — `expected RBRACE`, проверено `mlog check`).
   Блок `llm {}` в программе один, поэтому «по блоку на провайдера» не получится.
   Решение — до наряда этапа 1 (ТЗ §17 п. 15).
3. Документация Metalogos расходится с бинарём в мелочах (B.1) — правило `AGENTS.md` §2 «проверяет проба, не чтение» подтверждено.
