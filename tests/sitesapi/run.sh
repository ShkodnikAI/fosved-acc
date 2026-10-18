#!/usr/bin/env bash
# Тесты вкладки «Сайты» (наряд АСС-2.3, A.3) против настоящего mlog serve.
#   1. /api/sites без сессии → 401;
#   2. два сайта-фикстуры (зелёный и с открытым инцидентом) → цвета
#      green/red, совпадающие с текстом /status (юнит tests/sitesapi/run.mlog);
#   3. срок 5 дней → days: 5 (юнит + ответ API);
#   4. сайт на паузе → paused: true (юнит + ответ API);
#   5. JS-рендер — снимок DOM (node, tests/sitesapi/dom_test.js).
# Запуск из корня репо: bash tests/sitesapi/run.sh [путь к mlog]
# Ожидаемо: SITESAPI OK 5/5
set -uo pipefail

ML="${1:-mlog}"
PORT=10000
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_sitesapi.XXXXXX.log)"
SECRET="acc-sitesapi-test-secret"

cd "$ROOT"
# чистое окружение (тестовая гигиена)
for f in data/acc.db data/memory.db; do
  if [ -e "$f" ]; then
    echo "SITESAPI FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done
for slug in gsite rsite; do
  if [ -e "data/sites/$slug" ]; then
    echo "SITESAPI FAIL: data/sites/$slug уже существует"; exit 1
  fi
done
mkdir -p data/miniapp-static data/sites/gsite data/sites/rsite
cp modules/miniapp/static/app.html modules/miniapp/static/app.js modules/miniapp/static/app.css data/miniapp-static/
# паспорта-фикстуры (формат АDR-0002, как tests/polygon/duty/passport.json)
for slug in gsite rsite; do
  sed "s/pfake/s$slug/; s/18455/18459/" tests/polygon/duty/passport.json > "/tmp/pass-$slug.json"
  python3 - "$slug" <<'PY'
import json, sys
slug = sys.argv[1]
p = json.load(open(f"/tmp/pass-{slug}.json"))
p["slug"] = slug
p["name"] = "Зелёный тест" if slug == "gsite" else "Красный тест"
p["url"] = f"https://{slug}.example"
p["repo"]["health_url"] = f"https://{slug}.example/health"
json.dump(p, open(f"data/sites/{slug}/passport.json", "w"), ensure_ascii=False, indent=2)
PY
done

METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_HEARTBEAT_URL,ACC_SESSION_SECRET,ACC_PUBLIC_URL,METALOGOS_HTTP_ALLOW_PRIVATE" \
ACC_SESSION_SECRET="$SECRET" \
ACC_PUBLIC_URL="https://acc-test.example" \
METALOGOS_SERVE_ALLOW_EXEC=1 \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true; rm -rf data/sites/gsite data/sites/rsite data/miniapp-static; rm -f data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db data/checkpoints.db /tmp/pass-*.json' EXIT

up=0
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || true)"
  [ "$code" = "200" ] && up=1 && break
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "SITESAPI FAIL: сервер не поднялся"; tail -10 "$LOG"; exit 1
fi

ok=0; fail=0
chk() { if [ "$1" = "0" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi }

# ── данные фикстур: инициализация + записи (сессия не нужна — это подготовка
#    данных через mlog run в том же data/; run-режим, интерпретатор)
cat > tests/sitesapi/fixture.mlog <<'EOS'
import core/store as st
import core/ledger as lg

db { url: "sqlite:data/acc.db" }

pattern Main1(_: String) -> String {
  let _ = st.SiteInit("gsite")
  let g = st.SiteDb("gsite")
  let g1 = grant_issue("db:insert:" + g + ".health_checks", 60, "unlimited")
  let _ = db_execute_with_grant(g1, "INSERT INTO " + g + ".health_checks (ts, url, status, ms, text_ok, error) VALUES (?1, ?2, ?3, ?4, ?5, ?6)", [now() - 60.0, "https://gsite.example/", 200.0, 12.0, 1.0, "ok"])
  let g2 = grant_issue("db:insert:" + g + ".deadlines", 60, "unlimited")
  let _ = db_execute_with_grant(g2, "INSERT INTO " + g + ".deadlines (kind, subject, expires, source, checked_ts) VALUES ('domain', 'gsite.example', date('now', '+61 day'), 'rdap', ?1)", [now()])
  let g3 = grant_issue("db:insert:" + g + ".deadlines", 60, "unlimited")
  let _ = db_execute_with_grant(g3, "INSERT INTO " + g + ".deadlines (kind, subject, expires, source, checked_ts) VALUES ('cert', 'gsite.example', date('now', '+62 day'), 'rdap', ?1)", [now()])
  let _ = st.SiteInit("rsite")
  let r = st.SiteDb("rsite")
  let r1 = grant_issue("db:insert:" + r + ".health_checks", 60, "unlimited")
  let _ = db_execute_with_grant(r1, "INSERT INTO " + r + ".health_checks (ts, url, status, ms, text_ok, error) VALUES (?1, ?2, ?3, ?4, ?5, ?6)", [now() - 120.0, "https://rsite.example/", 0.0, 8.0, 0.0, "down"])
  let r2 = grant_issue("db:insert:" + r + ".incidents", 60, "unlimited")
  let _ = db_execute_with_grant(r2, "INSERT INTO " + r + ".incidents (opened_ts, closed_ts, kind, summary, notified_ts) VALUES (?1, NULL, 'down', 'down / тест', NULL)", [now() - 120.0])
  let r3 = grant_issue("db:insert:" + r + ".deadlines", 60, "unlimited")
  let _ = db_execute_with_grant(r3, "INSERT INTO " + r + ".deadlines (kind, subject, expires, source, checked_ts) VALUES ('domain', 'rsite.example', date('now', '+5 day'), 'rdap', ?1)", [now()])
  let _ = lg.Journal("rsite", "paused", "фикстура юнита: сайт на паузе")
  return "fixtures ok"
}

flow Main {
  input: String = "" -> Main1 -> output
}
EOS
"$ML" run tests/sitesapi/fixture.mlog > /dev/null 2>&1
chk "$?" "подготовка фикстур (mlog run)"

# ── юниты (тесты 2-4): цвета совпадают с /status, days 5, пауза
METALOGOS_ENV_ALLOWLIST="ACC_SESSION_SECRET" \
ACC_SESSION_SECRET="$SECRET" \
"$ML" run tests/sitesapi/run.mlog > /tmp/sitesapi-unit.out 2>/tmp/sitesapi-unit.err
chk "$?" "юниты POLYGON sitesapi 8/8 (цвета/days/пауза)"
grep -q "POLYGON sitesapi 8/8" /tmp/sitesapi-unit.out
chk "$?" "вердикт юнитов"

# ── тест 1: /api/sites без сессии → 401
r1="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/sites" || true)"
[ "$r1" = "401" ]; chk "$?" "1: /api/sites без сессии → 401"

# ── API с валидной сессией: цвета/paused/days в ответе
now="$(date +%s)"
tok="$((now + 900)).$(printf 'acc-app:%s' "$((now + 900))" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"
body="$(curl -s -H "X-ACC-Session: $tok" "http://127.0.0.1:$PORT/api/sites" || true)"
echo "api/sites: $body"
echo "$body" | grep -q '"color":"green"'
chk "$?" "2: green в ответе API"
echo "$body" | grep -q '"color":"red"'
chk "$?" "2: red в ответе API"
echo "$body" | grep -q '"paused":true'
chk "$?" "4: paused true в ответе API"
echo "$body" | grep -q '"days":5'
chk "$?" "3: days 5 в ответе API"
echo "$body" | grep -q '"open_incidents":\[{"kind":"down"'
chk "$?" "2: открытый инцидент в ответе API"

# ── тест 5: JS-рендер — снимок DOM (node)
node tests/sitesapi/dom_test.js > /tmp/sitesapi-dom.out 2>&1
chk "$?" "5: снимок DOM (node)"
grep -q "DOM SNAPSHOT OK" /tmp/sitesapi-dom.out
chk "$?"

if [ "$fail" = 0 ]; then
  echo "SITESAPI OK 5/5"
  exit 0
fi
echo "SITESAPI FAIL (ok=$ok fail=$fail)"
tail -10 "$LOG"
exit 1
