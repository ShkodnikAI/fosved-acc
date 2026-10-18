#!/usr/bin/env bash
# Полигон Секретаря (наряд АСС-1.5, A.5): serve-приложение полигона +
# HTTP-тесты webhook'а и доставки. Мок Telegram — на уровне шва SecSend
# (kv acc_mock_send=1, таблица mock_sends): базовый адрес api.telegram.org
# в 0.32.0 не переопределяется (проба сессии), поэтому фейк-Telegram-API
# на 127.0.0.1 невозможен — путь задокументирован в отчёте наряда.
# env-значения секрета/владельца — тестовые, не секреты; в проде задаются
# в Render (наряд АСС-1.6).
#
# Задачи:
#  1. неверный секрет webhook — 403;
#  2. чужой отправитель — молча 200, ответа нет, Journal «чужой
#     отправитель» без id;
#  3. /status при открытом инциденте — «КРАСНЫЙ»;
#  4. событие incident_open уходит один раз, повторный цикл не дублирует;
#  5. сводка в тот же день второй раз не уходит.
#
# Запуск из корня репо: bash tests/polygon/secretary/run.sh [путь к mlog]
# Ожидаемо: POLYGON secretary 5/5
set -uo pipefail

ML="${1:-mlog}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d /tmp/acc_polygon_sec.XXXXXX)"
ERRLOG="$(mktemp /tmp/acc_polygon_sec.XXXXXX.err)"
trap 'kill "$SERVE_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
SERVE_PID=""

# дерево запуска: продовые модули + паспорт tega + реестры
mkdir -p "$WORK/data/sites/tega" "$WORK/data/registry"
cp -r "$ROOT/core" "$WORK/core"
cp -r "$ROOT/modules" "$WORK/modules"
cp "$ROOT/sites/tega/passport.json" "$WORK/data/sites/tega/passport.json"
cp "$ROOT"/registry/*.json "$WORK/data/registry/"
cp "$ROOT/tests/polygon/secretary/serve_app.mlog" "$WORK/"
cp "$ROOT/tests/polygon/secretary/prologue.mlog" "$WORK/"

cd "$WORK"

# 1) prologue: мок-шов + фикстуры (та же БД и kv, что у serve)
"$ML" run prologue.mlog > prologue.out 2> prologue.err
if [ $? != 0 ]; then
  echo "POLYGON secretary FAIL: prologue"
  grep -v REDACT prologue.err | tail -3
  exit 1
fi

# 2) serve-процесс полигона (только localhost)
METALOGOS_ENV_ALLOWLIST="ACC_TELEGRAM_WEBHOOK_SECRET,ACC_OWNER_TG_ID,ACC_INTERNAL_TOKEN" \
ACC_TELEGRAM_WEBHOOK_SECRET="poly-webhook-secret-0123456789abcdef" \
ACC_OWNER_TG_ID="111222333" \
ACC_INTERNAL_TOKEN="poly-internal-token" \
"$ML" serve serve_app.mlog > serve.log 2>&1 &
SERVE_PID=$!

up=0
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18457/test/mock-count 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up=1; break; fi
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "POLYGON secretary FAIL: serve не поднялся"
  grep -v REDACT serve.log | tail -5
  exit 1
fi

BASE="http://127.0.0.1:18457"
ok=0
fail=0
mark() { if [ "$1" = "$2" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $3 (got [$1], want [$2])"; fi }

# ── задача 1: неверный секрет — 403 ──
c1a="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/tg" -d '{}')"
mark "$c1a" "403" "1a: без заголовка"
c1b="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/tg" -H "X-Telegram-Bot-Api-Secret-Token: wrong" -d '{}')"
mark "$c1b" "403" "1b: неверный секрет"

# ── задача 2: чужой отправитель — молча 200 + Journal без id ──
c2="$(curl -s -w "|%{http_code}" -X POST "$BASE/tg" -H "X-Telegram-Bot-Api-Secret-Token: poly-webhook-secret-0123456789abcdef" -d '{"message":{"text":"/status","from":{"id":999999},"chat":{"id":999999}}}')"
mark "${c2##*|}" "200" "2a: чужой → 200"
mark "${c2%%|*}" "{}" "2b: чужой → без ответа (пустое тело)"
outs="$(curl -s "$BASE/test/event-count?slug=tega&kind=outsider")"
mark "$outs" "1" "2c: Journal «чужой отправитель» записан"
mc2="$(curl -s "$BASE/test/mock-count")"
mark "$mc2" "0" "2d: чужому не отвечали (мок пуст)"

# ── задача 3: /status при открытом инциденте — КРАСНЫЙ ──
c3="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/tg" -H "X-Telegram-Bot-Api-Secret-Token: poly-webhook-secret-0123456789abcdef" -d '{"message":{"text":"/status","from":{"id":111222333},"chat":{"id":111222333}}}')"
mark "$c3" "200" "3a: /status владельца → 200"
red="$(curl -s "$BASE/test/mock-contains?needle=КРАСНЫЙ")"
mark "$red" "yes" "3b: ответ содержит КРАСНЫЙ"
mc3="$(curl -s "$BASE/test/mock-count")"
mark "$mc3" "1" "3c: ровно одно сообщение владельцу"

# ── задача 4: incident_open уходит один раз ──
d1="$(curl -s "$BASE/test/deliver")"
mc4="$(curl -s "$BASE/test/mock-count")"
pend="$(curl -s "$BASE/test/pending-count?slug=tega&kind=incident_open")"
mark "$mc4" "2" "4a: событие доставлено (2 мок-сообщения)"
mark "$pend" "0" "4b: sent_ts поставлен (недоставленных 0)"
d2="$(curl -s "$BASE/test/deliver")"
mc4b="$(curl -s "$BASE/test/mock-count")"
mark "$mc4b" "2" "4c: повторный цикл не дублирует"

# ── задача 5: сводка второй раз в тот же день не уходит ──
s1="$(curl -s "$BASE/test/summary")"
mc5="$(curl -s "$BASE/test/mock-count")"
mark "$mc5" "3" "5a: сводка отправлена (3 мок-сообщения)"
warnpend="$(curl -s "$BASE/test/pending-count?slug=tega&kind=deadline_warn")"
mark "$warnpend" "0" "5b: сводочным событиям поставлен sent_ts"
s2="$(curl -s "$BASE/test/summary")"
mc5b="$(curl -s "$BASE/test/mock-count")"
mark "$mc5b" "3" "5c: повторная сводка не уходит"

grep -v REDACT "$ERRLOG" >/dev/null 2>&1 || true
if [ "$fail" = 0 ]; then
  echo "POLYGON secretary 5/5"
else
  echo "POLYGON secretary FAIL (OK=$ok FAIL=$fail)"
  grep -v REDACT serve.log | grep -E "error|Error" | head -5 || true
  exit 1
fi
