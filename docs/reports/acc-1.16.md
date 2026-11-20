# Отчёт АСС-1.16

- Наряд: #54 (P0, runtime). Ветка: `acc-1.16-cron`.
- Цель: каждая cron-джоба АСС срабатывает и доходит до паттерна; утренняя сводка в 07:00 Europe/Minsk.

## Причина пустого хранилища (A.1)

**Факты (доступные без прод-консоли; строка `bootstrap:` с прода в окне лога 12–19.11 отсутствует — последний деплой c5fd38a прошёл 09.11, вне 7-дневной глубины логов):**

1. Прод жив и не в crash-loop: `https://fosved-acc.onrender.com/health` → 200 `{"status":"ok"}`, RT 0.24–0.67 с (три замера 20.11).
2. `ACC_INTERNAL_TOKEN` в Render **задан**: `GET /internal/duty/bootstrap?token=` (и без токена) → **401 unauthorized**, а не 503 «internal token not configured» (app.mlog:87-99: пустой `env("ACC_INTERNAL_TOKEN")` → 503). Значит и allowlist его содержит: иначе env() вернул бы Err и маршрут ответил бы 503.
3. Код регистрации корректен — доказано прод-симуляцией (та же схема, что Dockerfile/start.sh: сид → serve → три bootstrap-маршрута): все три вернули 200, в kv_store `data/memory.db` появились 4 джобы, `secretary-deliver` (*/1) файрилась каждую минуту (прод-сим: 15 firing за 15 мин).
4. «[memory]/[kv_store] Persistence enabled раз в 5 с» из факта аудитора — **это внешние пинги /health**, не scheduler: каждый HTTP-запрос к app.mlog печатает строку Persistence (прод-сим: 10 запросов → +10 строк; без запросов serve молчит часами). UptimeRobot/Render health-check каждые ~5с дают картину «раз в 5 с».
5. cron_jobs хранится в kv_store `data/memory.db` (ключ `cron_jobs`, таблица видна в SQLite; strings бинаря: `SELECT value FROM kv_store WHERE key = 'cron_jobs'`) и **переживает рестарт serve** (проба 15 + рестарт-проба: джоба на месте).

**Вывод A.1:** противоречие «прод жив + токен задан + 0 [cron] за 7 дней» снимается единственным образом: **на последнем старте (09.11 или позже) bootstrap-маршруты не вернули 200** — либо вернули не-200 (строка `bootstrap: duty=…` это показала бы), либо curl-таймаут (duty до 180 с; при живом сайте тик занимает секунды — маловероятно). Причина — в окружении Render на момент старта, не в коде (п.3). Файл-строка кода: `scripts/start.sh:57-63` (bootstrap после /health), `app.mlog:87-99` (fail-closed токен).

**Действие владельца (окружение, не код):** перезапустить сервис (Render → Manual Deploy → Restart) и прислать строку `bootstrap: duty=… deadlines=… secretary=…` из лога старта (без токена). По ней причина определяется однозначно: `200` — расписания зарегистрированы (после мержа этого PR — с правильными именами); `503` — не задан `ACC_INTERNAL_TOKEN` или его нет в `METALOGOS_ENV_ALLOWLIST` (runbook §2); `401` — рассинхрон значения токена между env и allowlist-строкой; `000` — таймаут curl; `skipped` — `ACC_INTERNAL_TOKEN` пуст в Environment.

## Проба короткого имени (B.1)

- `probes/14-cron-shortname.mlog` — PASS: cron_add принимает короткие имена паттернов (основная программа и импортированный модуль `modules/duty/schedule`), 2/2 в cron_list, remove чистый.
- Serve-проба (та же сессия, v0.39.0): `[cron] firing: */1 — Target` и `*/2 — ModTarget` (Target — в основной программе, ModTarget — в импортированном модуле), оба вызваны, 0 dispatch error → **обёртки в app.mlog не нужны**, гейт #523 резолвит импорт, call_pattern находит паттерн модуля по короткому имени.
- Доп. факты проб (для будущих нарядов): cron_add БЕЗ payload → диспатчер зовёт паттерн с 0 аргументов (паттерн с параметром → `expects 1 args, got 0`); с payload → паттерн получает его первым аргументом. Поэтому DutyTickAll/DeliverTickAll — zero-arg (payload не нужен), SecSummaryOnce/DlTickAll — `payload: String` (пара daily_at|tz).

## Имена до/после (B.1)

| Место | До (не паттерн) | После (имя паттерна) |
|---|---|---|
| modules/duty/schedule.mlog:128 | `duty-tick` | `DutyTickAll` |
| modules/secretary/deliver.mlog:287 | `secretary-deliver` | `DeliverTickAll` |
| modules/secretary/deliver.mlog:357 | `secretary-summary-<daily_at>-<tz>` | `SecSummaryOnce` + payload `daily_at\|tz` (5-й арг.) |
| modules/deadlines/run.mlog:364 | `deadlines-tick-<daily_at>-<tz>` | `DlTickAll` + payload `daily_at\|tz` |

Сверка «джоба уже есть» — по паре prompt+payload (несколько пар daily_at/tz → несколько джоб одного паттерна). Разделитель полей внутренних строк `;` (не `|` — payload содержит `|`). `grep -rn "cron_add(" modules/` — все 4 вызова указывают на существующие `pattern <Имя>(`.

## Миграция (B.2)

Bootstrap снимает старые джобы (duty-tick / secretary-deliver / secretary-summary-* / deadlines-tick-*) по id, если находит в хранилище:
- `tests/intakeapi/cron_migrate1.mlog` (внутрипроцессная): посадка 4 старых + три bootstrap → `CRONMIG dl07=1 duty=1 old=0 removed_old=1` — зелёный.
- Межпроцессная (хранилище со старыми ДО старта serve → bootstrap-маршруты): в serve-тесте `cron_dispatch.sh` — `/test/old-jobs` сеет 4 старых в kv serve-процесса, bootstrap-маршруты → `{"new":4.0,"old":0.0}` (старые 0, новые 4), отчёты: duty `removed_old=1`, deadlines `removed_stale=1`, secretary `deliver_removed_old=1 removed_stale=1`.
- Факт для B.2 (ограничение среды): в `mlog run` `memory { persist }` не материализуется (файл 0 байт, без таблиц) — kv-persist активен только под serve; поэтому межпроцессная миграция проверяется serve-тестом, а не run-прогонами.

## Serve-тест (C.1)

`tests/serve/cron_dispatch.sh` (CI, джоба serve, до 8 мин): живой `mlog serve` с продовыми модулями и тестовым паспортом pfav (все три модуля), мок-шов SecSend (идиома полигона АСС-1.13). Итог прогона:
- `[cron] firing:` для всех 4 джоб: DutyTickAll=1, DeliverTickAll=3, SecSummaryOnce=3, DlTickAll=3 (за ≤3 мин);
- **dispatch error = 0** после bootstrap (ошибки посаженных старых джоб до миграции не считаются — их промпты законно не паттерны);
- побочные эффекты: `site.health_checks` = 7 записей, kv `acc_summary_day` = сегодня (MATCH), `mock_sends` = 2 (сводка ушла в мок Telegram), таблица `deadlines` у сайта создана.

**Мутация:** возвращён `"secretary-deliver"` в cron_add (deliver.mlog:287) → тест КРАСНЫЙ: `{"new":3.0,"old":1.0}` — «старые джобы не сняты» (после bootstrap осталась 1 старая). Мутация откачена, повторный прогон зелёный.

## Прод после деплоя

Недоступно исполнителю (нет доступа к логам Render; действие владельца — см. A.1: перезапуск + строка `bootstrap:`). Ожидание после мержа+деплоя: `bootstrap: duty=200 deadlines=200 secretary=200`, затем `[cron] firing: */5 * * * * — DutyTickAll` с периодом из паспорта tega (uptime_every_min=5), `*/1 — DeliverTickAll` каждую минуту, 0 `dispatch … error` за час; утренняя сводка на следующий день в 07:00 Europe/Minsk.

## Не сделано / допущения

1. Причина A.1 на 100% не установлена — строка `bootstrap:` с прода вне досягаемости (нет доступа к Render; глубина логов 7 дней против старта 09.11). Передано владельцу точное действие (см. A.1). Код подтверждён корректным прод-симуляцией.
2. CI-прогон ветки не завершён к моменту сдачи отчёта (serve-тест до 8 мин в джобе serve) — ссылка на прогон будет в PR.
3. cron_run в run-режиме даёт `queued` (scheduler только в serve) — проба 14 проверяет регистрацию, диспатч — serve-тест C.1 (зафиксировано в самой пробе).
4. Волну 3 (#35) не трогал (запрет наряда). Пороги, тексты сводок, паспорта, пин Metalogos v0.39.0 — не тронуты.
