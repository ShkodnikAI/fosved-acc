#!/bin/sh
# АСС-1.11 (наряд #39, блок D — поправка аудитора 04.11): старт контейнера.
#
# Порядок (D.1): сид конфигурации (A.2) -> mlog serve -> ожидание /health
# (до 180 с) -> регистрация расписаний через внутренние bootstrap-маршруты
# -> wait serve (сигналы TERM/INT передаются процессу serve).
#
# Зачем: расписания Дежурного (duty-tick), Дедлайнов (deadlines-tick-*) и
# Секретаря (secretary-deliver, утренняя сводка) регистрируют ТОЛЬКО
# маршруты /internal/{duty,deadlines,secretary}/bootstrap (app.mlog:76-135).
# До блока D на проде их никто не вызывал — Healthchecks «ACC Дежурный»
# не получал ни одного пинга (Last Ping: Never), цикл Дежурного не ходил.
# Bootstrap вызывается ПОСЛЕ сида: DutyBootstrap идёт по data/sites
# (modules/duty/schedule.mlog:86).
#
# Идемпотентность: bootstrap-маршруты ставят cron_add только после
# cron_list (дублей при повторном старте нет — проверка D.2 в CI).
# Токен не печатается: URL и тело ответов подавлены (-o /dev/null),
# печатается только одна строка с кодами ответов.
#
# Пустой ACC_INTERNAL_TOKEN -> строка «bootstrap: skipped (…)», serve
# продолжает работать (fail-safe, D.1). На проде ACC_INTERNAL_TOKEN и
# METALOGOS_ENV_ALLOWLIST (с ACC_INTERNAL_TOKEN в списке) задаются в
# Render по docs/runbook/deploy.md §2 — без них маршруты вернут 503
# «internal token not configured», что будет видно в этой строке.

set -u

PORT=10000
touch /app/data/.keep
/app/scripts/seed-data.sh

# №259 (переход v0.40.1, 26.11): env() в телах маршрутов serve — явный ключ

# (allowlist METALOGOS_ENV_ALLOWLIST скоупит имена, см. entrypoint).

METALOGOS_SERVE_ALLOW_ENV=1 \


mlog serve app.mlog &
PID=$!
term() { kill -TERM "$PID" 2>/dev/null || true; }
trap term TERM INT

# D.1.3: ждём готовности serve до 180 с; если serve умер — выходим сразу.
i=0
while [ "$i" -lt 180 ]; do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then break; fi
  kill -0 "$PID" 2>/dev/null || break
  i=$((i + 1))
  sleep 1
done

# D.1.4: три bootstrap-маршрута, только localhost, тело и URL подавлены,
# одна строка с кодами ответов (duty — до 180 с: при сбое сайта цикл
# подтверждения ждёт 60 с, tests/serve/duty_serve.sh:81).
# #54 A.1-бис (аудит 20.11): токен — заголовком X-Internal-Token, не в
# query. Символы +/=&%# в ACC_INTERNAL_TOKEN искажаются разбором query
# («+» → пробел и т.д.) → все три маршрута давали 401 при верном токене
# (оба старта прода 20.11: duty=401 deadlines=401 secretary=401, хранилище
# cron пустое, [cron] firing = 0). Заголовок доходит дословно — проба 16
# (probes/16-header-token.mlog: спецсимвольный токен заголовком → match,
# тот же в query → mismatch). Токен в URL также противоречит правилу
# «не в URL» (CONTRACT.md §1 снабженца, AGENTS.md §5 АСС).
# -H выносит значение из командной строки curl в аргумент curl (виден в
# ps внутри контейнера так же, как прежде в URL) — в лог не попадает:
# вывод подавлён (-o /dev/null), печатается только строка с кодами.
if [ -n "${ACC_INTERNAL_TOKEN:-}" ]; then
  d=$(curl -s -o /dev/null -w '%{http_code}' --max-time 180 -H "X-Internal-Token: ${ACC_INTERNAL_TOKEN}" "http://127.0.0.1:${PORT}/internal/duty/bootstrap")
  l=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -H "X-Internal-Token: ${ACC_INTERNAL_TOKEN}" "http://127.0.0.1:${PORT}/internal/deadlines/bootstrap")
  s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -H "X-Internal-Token: ${ACC_INTERNAL_TOKEN}" "http://127.0.0.1:${PORT}/internal/secretary/bootstrap")
  echo "bootstrap: duty=${d} deadlines=${l} secretary=${s}"
else
  echo "bootstrap: skipped (ACC_INTERNAL_TOKEN не задан)"
fi

# D.1.5: остаёмся в контейнере, пока работает serve; SIGTERM/SIGINT
# передаются serve через trap term выше.
wait "$PID"
