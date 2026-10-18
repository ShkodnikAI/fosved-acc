# Runbook: сервис АСС на Render, деплой из CI, внешние сторожа, бот

Наряд АСС-1.6 (A.1). Пошагово, без пропусков. Действия исполнителя не
закрывают: шаги выполняет владелец. Значения секретов нигде не печатаются
и в чат/репозиторий не присылаются.

## 1. Сервис Render

1. Открыть <https://dashboard.render.com> → **New → Web Service**.
2. **Existing image → подключить репозиторий** `ShkodnikAI/fosved-acc`
   (или «Deploy from repo», Runtime: **Docker** — образ собирается из
   `Dockerfile` корня репо).
3. Регион: **Frankfurt**.
4. Instance Type: **Starter** (требуется диск).
5. **Disks**: Add Disk → Mount path `/app/data`, Size **1 ГБ**
   (WORKDIR `/app`, `Dockerfile:17`; на смонтированном диске контейнер
   сам создаёт `data/.keep` и `data/sites` при старте — `Dockerfile`, CMD).
6. **Auto-Deploy: Off** (деплой только из CI по хуку — запрет наряда).
7. Создать сервис.
8. Примечание о диске: контейнер работает от непривилегированного пользователя
   (`acc`, Dockerfile). Диск должен быть записываем этим пользователем; если
   в логах контейнера `touch /app/data/.keep: Permission denied` — сообщить
   аудитору (известное ограничение Render для non-root + disk), не обходить.

## 2. Environment (имена, значения — сюда же в Render)

Добавить переменные (значения не присылать в чат/репозиторий):

| Имя | Что положить |
|---|---|
| `ACC_INTERNAL_TOKEN` | случайная строка (например, `openssl rand -hex 32`) — токен внутренних маршрутов |
| `TELEGRAM_BOT_TOKEN_ACC` | токен бота АСС из @BotFather |
| `ACC_TELEGRAM_WEBHOOK_SECRET` | случайная строка 32+ символов — секрет webhook Telegram |
| `ACC_OWNER_TG_ID` | Telegram id владельца (только он получает ответы) |
| `ACC_HEARTBEAT_URL` | полный ping-адрес Healthchecks.io из шага 4 |
| `METALOGOS_ENV_ALLOWLIST` | точный список: `ACC_INTERNAL_TOKEN,ACC_OWNER_TG_ID,ACC_TELEGRAM_WEBHOOK_SECRET,ACC_HEARTBEAT_URL,TELEGRAM_BOT_TOKEN_ACC` |

## 3. Deploy Hook → секрет GitHub

1. Render → сервис → **Settings → Deploy Hook** → скопировать URL
   (вида `https://api.render.com/deploy/srv-…?id=…`).
2. GitHub → репозиторий `ShkodnikAI/fosved-acc` → **Settings → Secrets
   and variables → Actions → New repository secret**: имя
   `ACC_RENDER_DEPLOY_HOOK`, значение — скопированный URL.
3. URL хука нигде больше не сохранять и в логи не выводить.

## 4. Внешние сторожа

**UptimeRobot** (<https://uptimerobot.com>):
1. Add New Monitor → HTTP(s).
2. URL: `https://<имя-сервиса>.onrender.com/health`.
3. Интервал: **5 минут**.
4. Alert Contacts: Telegram и/или почта владельца.

**Healthchecks.io** (<https://healthchecks.io>) — «мёртвая рука»:
1. Add Check → Period **10 минут**, Grace **10 минут**.
2. Открыть check → скопировать **ping URL** (вида
   `https://hc-ping.com/<uuid>`) → вставить в Render как значение
   `ACC_HEARTBEAT_URL` (шаг 2).
3. Интеграция оповещений: Telegram/почта владельца.

Смысл двух слоёв (ТЗ §12, исследование C.4): UptimeRobot ловит
«сервис недоступен/503», Healthchecks — «жив, но цикл Дежурного не
ходит» (АСС сам пингует после каждого успешного цикла).

## 5. Вебхук бота АСС

1. Render → сервис → **Manual Deploy → Deploy latest commit**
   (первый деплой вручную) и дождаться статуса Live.
2. Выполнить setWebhook **без вывода токена в терминал/лог** — заменить
   два placeholder'а в файле команды и запустить её (значения подставит
   редактор, история shell не сохранит, если выполнить из файла):

   ```bash
   cat > /tmp/setwh.sh <<'EOS'
   #!/usr/bin/env bash
   # значения подставить перед запуском; файл удалить после
   TOKEN="__TELEGRAM_BOT_TOKEN_ACC__"
   SECRET="__ACC_TELEGRAM_WEBHOOK_SECRET__"
   curl -fsS "https://api.telegram.org/bot${TOKEN}/setWebhook" \
        -d "url=https://<имя-сервиса>.onrender.com/tg" \
        -d "secret_token=${SECRET}" \
        -d "allowed_updates=[\"message\"]" \
     | python3 -c "import json,sys; d=json.load(sys.stdin); print('setWebhook ok:', d.get('ok'), d.get('description',''))"
   EOS
   sh /tmp/setwh.sh && rm -f /tmp/setwh.sh
   ```
   В ответе только `ok: True` — токен не выводится.

## 6. Приёмка (A.4 наряда)

1. CI push в main → джоба deploy → Render → Events: деплой с `commit` =
   SHA коммита (сверить в Render; джоба `deploy` печатает только код
   ответа, URL не выводится).
2. `curl -fsS https://<имя-сервиса>.onrender.com/health` →
   `{"checks":{...},"status":"ok"}`.
3. `curl -fsS "https://<имя-сервиса>.onrender.com/internal/ledger/verify?token=<ACC_INTERNAL_TOKEN>"`
   → `{"ok":true,"count":N}` (токен не выводить в логи).
4. Через 15 минут: UptimeRobot — up; Healthchecks — up (пинги пошли).
5. Написать боту `/status` → ответ с цветом сайтов (ожидание:
   «ТЭГА ПЛЮС — зелёный»).
6. **Искусственный сбой** (критерий этапа 1 ТЗ §16): PR с изменением
   контрольного текста `/kontakty` в `sites/tega/passport.json` на
   несуществующий → мерж (CI зелёный → deploy) → за 5–10 минут приходит
   `incident_open`; PR-откат → `incident_close`.
7. На следующее утро в `daily_at` (07:00 Europe/Minsk) приходит сводка.

## Если что-то не так

- `/health` 503 `degraded` на новом диске — проверьте, что образ собран
  из свежего main (CMD создаёт `data/.keep`; фикс АСС-1.6 A.3a).
- Deploy-джоба красная с текстом «секрет … не задан» — секрет
  `ACC_RENDER_DEPLOY_HOOK` не заведён (шаг 3).
- Бот молчит: проверьте setWebhook (шаг 5) и `ACC_TELEGRAM_WEBHOOK_SECRET`
  в Render — они должны совпадать.
