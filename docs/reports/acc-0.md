# Отчёт АСС-0

- Наряд: #1. Ветка: `acc-0/skeleton`. PR: #2.
- Исполнитель: Claude (по прямому поручению владельца 16.10.2026; наряд писал тот же Claude в роли аудитора — **приёмку стоит провести другой сессии**, AGENTS.md §1).
- CI на коммите сдачи: все блокирующие джобы зелёные — ссылка в комментарии к PR.

## A. Каркас

**A.1 Структура.** `find . -type d -not -path './.git*' | sort`:
`. ./adapters ./core ./data ./docs ./docs/adr ./docs/reports ./library ./modules ./probes ./probes/fixtures ./profiles ./registry ./scripts ./scripts/research ./sites ./skills ./tests ./tests/polygon`.
Каталоги ТЗ §4 есть, в каждом — README на 1–3 строки. Гард `scripts/check_layout.sh` (джоба CI «Layout») — `layout OK`.

**A.2 Документы.** `README.md`, `AGENTS.md` (разделы «Роли», «Контракт наряда», «Секреты», правило синхронизации, правила Metalogos), `CLAUDE.md` (ссылка), `docs/adr/0001-decisions-2026-10-16.md` (7 решений дословно по ТЗ), `.github/ISSUE_TEMPLATE/naryad.md` (по образцу FOSVED-office-v2, ссылки на §4 AGENTS.md).

**A.3 Docker.** `Dockerfile`: `ubuntu:24.04`, `MLOG_VERSION=v0.32.0`, `sha256sum -c` — `dd8164b747aa99cb953d3f7a29e084ba38d432df376aa2f05cfd2187e2bc59a2`. Хеш релиза совпадает с `tega-platform/Dockerfile` и с `FOSVED-office-v2/bin/mlog` (проверено `sha256sum` скачанного релиза: совпадение). Пользователь `acc` без root. На сборке — `mlog check` и `mlog audit app.mlog`. Локально Docker-демон в среде исполнителя недоступен — сборка и запуск проверены в CI (джоба «Docker build + /health»).

**A.4 `/health`.** `app.mlog`: один маршрут, `middleware: [rate_limit, security_headers]`. Проверяет `data/.keep` и `SELECT 1` в SQLite; любая проверка не прошла → `degraded` и HTTP 503.
- `mlog check app.mlog` → `OK: no issues found`; `mlog audit app.mlog` → `Summary: 2 passed`, 0 `[ERROR]`.
- Локально: `{"checks":{"data_dir":true,"sqlite":true},"status":"ok"} HTTP200`; без `data/.keep` — `{"checks":{"data_dir":false,"sqlite":true},"status":"degraded"} HTTP503`.
- В CI из контейнера: `{"checks":{"data_dir":true,"sqlite":true},"status":"ok"}` (аннотация `health`).

**A.5 `.env.example`.** Три имени (`METALOGOS_ENV_ALLOWLIST`, `METALOGOS_DATA_DIR`, `PORT`) без значений; гард в `check_layout.sh` падает, если у переменной появится значение.

**A.6 CI** (`.github/workflows/ci.yml`): Layout; mlog check+audit (все `*.mlog`, кроме негативных фикстур проб; `[ERROR]` роняет джобу); Probes (FAIL роняет, ABSENT допустим, итоги — в аннотациях); gitleaks по всей истории; Docker build + `/health` = ok; Research (информационная, `continue-on-error`, не влияет на качество кода — исключение из правила «пропуск не зеленеет» названо явно в имени джобы).
- **Красный прогон-доказательство:** PR #3 с намеренной синтаксической ошибкой в `app.mlog` → прогон https://github.com/ShkodnikAI/fosved-acc/actions/runs/38854146575: «mlog check + audit» — failure, «Docker build + /health» — failure, остальные — success. PR #3 закрыт без мержа.

## B. Пробы Metalogos 0.32.0

Таблица — `docs/reports/probes-0.32.md`. Итог: 9 × PASS, 1 × ABSENT (B.9: у провайдеров в блоке `llm {}` нет собственной модели). Одинаково локально и в CI.

## C. Исследование

`docs/reports/research-stage0.md`:
- C.1: ключ API Render — на весь аккаунт, сузить нельзя → в АСС не храним; деплой через Deploy Hook, параметр `ref=<SHA>` подтверждён документацией.
- C.2: pravo.by и tnpa.by с раннера GitHub недоступны (000 / 403) → мониторинг ТНПА из облака АСС по прямой схеме не заработает.
- C.3: `.by` — срок домена читается по WHOIS автоматически; `.plus` — RDAP реестра ответил 403 с раннера.
- C.4: внешний пинг `/health` + «мёртвая рука» на цикле расписания, оба бесплатно; рекомендация — оба.

## Расхождения с ТЗ

1. **ТЗ §4.1 / §4 принцип «модели через реестр и маршрутизатор, у каждого провайдера своя модель»** нельзя реализовать средствами блока `llm {}` (B.9 ABSENT). Нужно решение: свой маршрутизатор поверх `http_post` или запрос в Metalogos (ТЗ §17 п. 15).
2. **ТЗ §9 (мониторинг ТНПА)** предполагает чтение pravo.by/tnpa.by из АСС; с зарубежного адреса дата-центра сайты недоступны (C.2). Нужен белорусский адрес (агент) или почтовая подписка.
3. **ТЗ §5 поле `[domain] expires`** «из публичного реестра»: для `.plus` автоматически не получено (C.3).
4. **ТЗ §17 п. 2** закрыт: ключ Render — на весь аккаунт.

## Затруднения

1. Доступ к `fosved-acc` появился после того, как владелец добавил репозиторий в приложение Claude на GitHub.
2. Логи и артефакты раннера GitHub из среды исполнителя не читаются (хранилище логов отвечает 403) — итоги проб, `/health` и исследования выводятся в аннотации и читаются через API check-runs.
3. Прямые запросы к pravo.by, tnpa.by и RDAP из среды исполнителя требуют разрешения владельца — перенесены в CI.
4. Ветку `acc-0/red-proof` (PR #3, закрыт) удалить из среды исполнителя не удалось (`remote end hung up`) — владелец может удалить её кнопкой в GitHub.
