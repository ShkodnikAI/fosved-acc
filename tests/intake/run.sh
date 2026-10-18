#!/usr/bin/env bash
# Тесты приёма сайта (наряд АСС-2.5, A.3): фейк-сайты + разведка.
#   1. сайт с /be/, /en/, /health → языки [ru,be,en], health_url найден;
#   2. без /health → health_url: null, в found_auto его нет;
#   3. истёкшее временное разрешение → HttpAllowed false, SafeGet отказ;
#   4. черновик проходит ValidatePassportDraft (null допустим);
#   5. повторная заявка — одна запись в intake_drafts;
#   + VM-проба: команда «прими сайт …» через POST /tg (бот-путь) —
#     черновик появляется в data/acc.db (intake_drafts).
# ALLOW_PRIVATE / ALLOW_EXEC — только в тесте.
# Запуск из корня репо: bash tests/intake/run.sh [путь к mlog]
# Ожидаемо: INTAKE OK (юниты 7/7 + VM-проба бота)
set -uo pipefail

ML="${1:-mlog}"
PORT=10000
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_intake.XXXXXX.log)"
SECRET="acc-intake-test-secret"
OWNER_TG="123456789"

cd "$ROOT"
for f in data/acc.db data/memory.db; do
  if [ -e "$f" ]; then
    echo "INTAKE FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done
if [ -e data/sites ]; then
  echo "INTAKE FAIL: data/sites уже существует"; exit 1
fi
mkdir -p data/sites/journal data/miniapp-static
cp modules/miniapp/static/app.html modules/miniapp/static/app.js modules/miniapp/static/app.css data/miniapp-static/

python3 tests/intake/fake_intake_site.py > /tmp/acc_intake_fake.log 2>&1 &
FAKE=$!

# ── юниты (тесты 1–5, run-режим)
METALOGOS_ENV_ALLOWLIST="ACC_SESSION_SECRET" \
ACC_SESSION_SECRET="acc-intake-sess" \
METALOGOS_ALLOW_EXEC=1 \
METALOGOS_HTTP_ALLOW_PRIVATE=1 \
"$ML" run tests/intake/run.mlog > /tmp/intake-unit.out 2>/tmp/intake-unit.err
UNIT_RC=$?
grep -E "POLYGON" /tmp/intake-unit.out
[ "$UNIT_RC" = "0" ] && grep -q "POLYGON intake 7/7" /tmp/intake-unit.out
chk "$?" "юниты POLYGON intake 7/7 (тесты 1–5)"

METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_SESSION_SECRET,ACC_PUBLIC_URL,ACC_TELEGRAM_WEBHOOK_SECRET,ACC_OWNER_TG_ID,METALOGOS_HTTP_ALLOW_PRIVATE" \
ACC_SESSION_SECRET="acc-intake-sess" \
ACC_PUBLIC_URL="https://acc-test.example" \
ACC_TELEGRAM_WEBHOOK_SECRET="$SECRET" \
ACC_OWNER_TG_ID="$OWNER_TG" \
METALOGOS_HTTP_ALLOW_PRIVATE=1 \
METALOGOS_ALLOW_EXEC=1 \
METALOGOS_SERVE_ALLOW_EXEC=1 \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" "$FAKE" 2>/dev/null || true; rm -rf data/sites data/miniapp-static; rm -f data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db data/checkpoints.db' EXIT

up=0
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:18488/health" 2>/dev/null && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "INTAKE FAIL: фейк-сайт не поднялся"; tail -5 /tmp/acc_intake_fake.log; exit 1; }
up=0
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || true)"
  [ "$code" = "200" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "INTAKE FAIL: сервер не поднялся"; tail -10 "$LOG"; exit 1; }

ok=0; fail=0
chk() { if [ "$1" = "0" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi }

# ── VM-проба: команда бота через POST /tg (бот-путь, serve/VM)
TG_BODY="{\"update_id\":1,\"message\":{\"message_id\":1,\"from\":{\"id\":$OWNER_TG},\"text\":\"прими сайт http://127.0.0.1:18488\"}}"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Telegram-Bot-Api-Secret-Token: $SECRET" -H "Content-Type: application/json" -d "$TG_BODY" "http://127.0.0.1:$PORT/tg" || true)"
[ "$code" = "200" ]; chk "$?" "VM-проба: POST /tg → 200"
sleep 2
python3 - <<'PY'
import sqlite3, sys
con = sqlite3.connect("data/acc.db")
n = con.execute("SELECT COUNT(*) FROM intake_drafts WHERE url = 'http://127.0.0.1:18488'").fetchone()[0]
assert n >= 1, f"VM-путь: черновика нет (n={n})"
draft = con.execute("SELECT draft FROM intake_drafts WHERE url = 'http://127.0.0.1:18488'").fetchone()[0]
assert '"languages":["ru","be","en"]' in draft, "VM-путь: языки не собраны"
assert '"health_url":"http://127.0.0.1:18488/health"' in draft, "VM-путь: health_url не найден"
print("VM BOT PATH OK")
PY
chk "$?" "VM-проба: черновик бота в acc.db (языки+health_url)"

if [ "$fail" = 0 ]; then
  echo "INTAKE OK (юниты 7/7 + VM-проба бота)"
  exit 0
fi
echo "INTAKE FAIL (ok=$ok fail=$fail)"
tail -10 "$LOG"
exit 1
