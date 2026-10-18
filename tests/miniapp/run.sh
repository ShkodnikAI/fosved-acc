#!/usr/bin/env bash
# Тесты Mini App (наряд АСС-2.2, A.3): 7 тестов против настоящего
# mlog serve app.mlog + юниты сессии. Токены вычисляются клиентом
# (как это делает бот в проде): openssl dgst -sha256 -hmac.
#
#  1. валидный токен → /api/whoami 200 {"ok":true}
#  2. просроченный → 401
#  3. подпись чужим секретом → 401
#  4. мусор → 401
#  5. пустой ACC_SESSION_SECRET → 503 (/api/whoami и /app)
#  6. токен-подобный sig сравнивается верно — юнит tests/miniapp/session.mlog
#     (регресс ловушки Metalogos-#1317)
#  7. в ответах /app* нет внешних URL: grep -E "https?://" modules/miniapp/static/ → пусто
#
# Плюс: статика /app /app.js /app.css — 200 и Cache-Control: no-store.
#
# Запуск из корня репо: bash tests/miniapp/run.sh [путь к mlog]
# Ожидаемо: MINIAPP OK 7/7
set -uo pipefail

ML="${1:-mlog}"
PORT=10000
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_miniapp.XXXXXX.log)"
SECRET="acc-miniapp-test-secret"

cd "$ROOT"
# чистое окружение (тестовая гигиена): зеркало статики в data/
for f in data/acc.db data/memory.db; do
  if [ -e "$f" ]; then
    echo "MINIAPP FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done
mkdir -p data/miniapp-static
cp modules/miniapp/static/app.html modules/miniapp/static/app.js modules/miniapp/static/app.css data/miniapp-static/

METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_HEARTBEAT_URL,ACC_SESSION_SECRET,ACC_PUBLIC_URL" \
ACC_SESSION_SECRET="$SECRET" \
ACC_PUBLIC_URL="https://acc-test.example" \
METALOGOS_SERVE_ALLOW_EXEC=1 \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true; rm -rf data/miniapp-static; rm -f data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db data/checkpoints.db' EXIT

up=0
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || true)"
  [ "$code" = "200" ] && up=1 && break
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "MINIAPP FAIL: сервер не поднялся"; tail -10 "$LOG"; exit 1
fi

# токен клиента (как бот): exp.sig, sig = HMAC-SHA256(secret, "acc-app:<exp>") hex
now="$(date +%s)"
tok_ok="$((now + 900)).$(printf 'acc-app:%s' "$((now + 900))" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"
tok_old="$((now - 100)).$(printf 'acc-app:%s' "$((now - 100))" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"
tok_forg="$((now + 900)).$(printf 'acc-app:%s' "$((now + 900))" | openssl dgst -sha256 -hmac "wrong-secret" | awk '{print $NF}')"

ok=0; fail=0
chk() { if [ "$1" = "$2" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $3 (got [$1], want [$2])"; fi }

# 1: валидный токен → 200 {"ok":true}
r1="$(curl -s -o /dev/null -w '%{http_code}' -H "X-ACC-Session: $tok_ok" "http://127.0.0.1:$PORT/api/whoami" || true)"
chk "$r1" "200" "1: валидный токен → 200"
b1="$(curl -s -H "X-ACC-Session: $tok_ok" "http://127.0.0.1:$PORT/api/whoami" || true)"
chk "$b1" '{"ok":true}' "1: тело → {\"ok\":true}"
# 2: просроченный → 401
r2="$(curl -s -o /dev/null -w '%{http_code}' -H "X-ACC-Session: $tok_old" "http://127.0.0.1:$PORT/api/whoami" || true)"
chk "$r2" "401" "2: просроченный → 401"
# 3: подпись чужим секретом → 401
r3="$(curl -s -o /dev/null -w '%{http_code}' -H "X-ACC-Session: $tok_forg" "http://127.0.0.1:$PORT/api/whoami" || true)"
chk "$r3" "401" "3: чужая подпись → 401"
# 4: мусор → 401
r4="$(curl -s -o /dev/null -w '%{http_code}' -H "X-ACC-Session: garbage" "http://127.0.0.1:$PORT/api/whoami" || true)"
chk "$r4" "401" "4: мусор → 401"
# статика: /app /app.js /app.css — 200 + Content-Type + Cache-Control: no-store
h_app="$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/app" | tr -d '\r')"
echo "$h_app" | grep -qi "^HTTP/.* 200" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app 200"; }
echo "$h_app" | grep -qi "^Content-Type: text/html" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app Content-Type"; }
echo "$h_app" | grep -qi "^Cache-Control: no-store" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app Cache-Control"; }
h_js="$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/app.js" | tr -d '\r')"
echo "$h_js" | grep -qi "^HTTP/.* 200" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app.js 200"; }
echo "$h_js" | grep -qi "application/javascript" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app.js Content-Type"; }
echo "$h_js" | grep -qi "^Cache-Control: no-store" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app.js Cache-Control"; }
h_css="$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/app.css" | tr -d '\r')"
echo "$h_css" | grep -qi "^HTTP/.* 200" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app.css 200"; }
echo "$h_css" | grep -qi "text/css" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app.css Content-Type"; }
echo "$h_css" | grep -qi "^Cache-Control: no-store" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app.css Cache-Control"; }
# тело /app — HTML каркаса дошёл без искажений
body_app="$(curl -s "http://127.0.0.1:$PORT/app")"
echo "$body_app" | grep -q 'id="tabs"' && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app тело каркаса"; }
# JS дошёл без маскирования (токен-подобных констант в JS нет — bridge не должен резать)
body_js="$(curl -s "http://127.0.0.1:$PORT/app.js")"
echo "$body_js" | grep -q "X-ACC-Session" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: /app.js тело"; }

# 5: пустой ACC_SESSION_SECRET → 503 (второй сервер без секрета)
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null || true
METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_HEARTBEAT_URL,ACC_PUBLIC_URL" \
ACC_PUBLIC_URL="https://acc-test.example" \
METALOGOS_SERVE_ALLOW_EXEC=1 \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
up=0
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || true)"
  [ "$code" = "200" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "MINIAPP FAIL: второй сервер не поднялся"; tail -10 "$LOG"; exit 1; }
r5a="$(curl -s -o /dev/null -w '%{http_code}' -H "X-ACC-Session: $tok_ok" "http://127.0.0.1:$PORT/api/whoami" || true)"
chk "$r5a" "503" "5: пустой секрет → whoami 503"
r5b="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/app" || true)"
chk "$r5b" "503" "5: пустой секрет → /app 503"

# 6: юниты сессии (тест 6 — регресс #1317)
u="$(METALOGOS_ENV_ALLOWLIST="ACC_SESSION_SECRET" ACC_SESSION_SECRET="$SECRET" "$ML" run tests/miniapp/session.mlog 2>/dev/null)"
echo "$u"
echo "$u" | grep -q "POLYGON miniapp-session 3/3" && ok=$((ok+1)) || { fail=$((fail+1)); echo "FAIL: 6: юниты сессии"; }

# 7: нет внешних URL в статике (только относительные пути)
if grep -rnE "https?://" modules/miniapp/static/; then
  fail=$((fail+1)); echo "FAIL: 7: внешние URL в static/"
else
  ok=$((ok+1))
fi

if [ "$fail" = 0 ]; then
  echo "MINIAPP OK 7/7 (проверок: $ok)"
  exit 0
fi
echo "MINIAPP FAIL (ok=$ok fail=$fail)"; tail -10 "$LOG"
exit 1
