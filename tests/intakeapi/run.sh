#!/usr/bin/env bash
# Тесты вкладки «Приём» (наряд АСС-2.6, A.5) против настоящего mlog serve
# app.mlog с моком GitHub (tests/registryapi/mock_github.py) и фейк-сайтами
# разведки (tests/intake/fake_intake_site.py):
#   A.5.5. «мерж» (фикстура паспорта) + рестарт → cron_list содержит задание
#          Дежурного для нового slug (существующая регистрация расписаний
#          #39, код не меняется) — два прогона mlog run (каждый = старт);
#   A.5.1. форма с ошибкой slug → ошибка у поля, PR не создаётся;
#   A.5.2. пробный прогон на фейковом сайте не пишет incidents/events
#          (счётчики до и после равны) и не создаёт data/sites/<slug>/;
#   A.5.3. «Принять» при красном прогоне без отметки → 400;
#   A.5.4. валидный паспорт → мок GitHub получил файл, который проходит
#          ValidatePassport; черновик получил статус pr_open.
#   + рендер вкладки — node (tests/intakeapi/dom_intake.js);
#   + в выводе теста нет значения токена (grep).
# ALLOW_PRIVATE / ALLOW_EXEC / SERVE_EXEC / SERVE_BACKEND=interpreter —
# только в тесте (прод-значения — Dockerfile).
# Запуск из корня репо: bash tests/intakeapi/run.sh [путь к mlog]
# Ожидаемо: INTAKEAPI OK 6/6
set -uo pipefail

ML="${1:-mlog}"
PORT=10000
MOCKPORT=18477
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_intakeapi.XXXXXX.log)"
MOCKLOG="$(mktemp /tmp/acc_mock_gh.XXXXXX.jsonl)"
FAKELOG="$(mktemp /tmp/acc_intakeapi_fake.XXXXXX.log)"
TOKEN="acc-intakeapi-test-token-0123456789"
SECRET="acc-intakeapi-secret"

cd "$ROOT"
# чистое окружение (тестовая гигиена, как в tests/registryapi/run.sh)
for f in data/acc.db data/memory.db; do
  if [ -e "$f" ]; then
    echo "INTAKEAPI FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done
if [ -e data/registry ]; then
  echo "INTAKEAPI FAIL: data/registry уже существует"; exit 1
fi
# NB: data/sites в джобе store — общая по шагам (изоляция #44 оставляет
# aa/bb); моему тесту leftover-каталоги без passport.json безвредны, но
# дерево пересоздаём заново — фикстуры не должны видеть чужие паспорта
rm -rf data/sites

mkdir -p data/registry data/miniapp-static
cp modules/miniapp/static/app.html modules/miniapp/static/app.js modules/miniapp/static/app.css data/miniapp-static/
mkdir -p data/sites/journal data/sites/one data/sites/tfake
# реестр источников — для правила 9 валидатора (файл обязан существовать)
cat > data/registry/sources.json <<'EOS'
[
{"domain":"data.iana.org","frequency":"weekly","id":"rdap-iana","kind":"registry","read_method":"http","status":"active","terms_checked":true}
]
EOS
cat > data/registry/models.json <<'EOS'
[]
EOS

# паспорт сайта one — БЕЗ модуля duty (старт №1: duty-tick не нужен)
python3 - <<'PY'
import json
base = {
  "slug": "one", "name": "Первый", "url": "https://one.example",
  "languages": ["ru"], "timezone": "Europe/Minsk",
  "people": {"approver_tg_env": "ACC_OWNER_TG_ID", "editor_tg_env": None, "expert_tg_env": None},
  "repo": {"github": None, "branch": "main", "deploy": "render_hook",
           "health_url": None, "key_envs": []},
  "checks": {"uptime_every_min": 5, "daily_at": "07:00",
             "pages": [{"path": "/", "expect_text": "x"}]},
  "modules": ["deadlines"],
  "limits": {"tokens_per_day": 0, "deploys_per_day": 0},
  "domain": {"registrar": None, "registrar_panel_url": None, "expires": None,
             "expires_source": "auto", "cert_expires": None, "autorenew": None,
             "dns_provider": None, "warn_days": [60, 30, 7], "renewal_owner": "owner"},
  "profile": "showcase", "participation": "pr_with_approval",
  "platform": {"adapter": "render", "cdn": None},
  "models": {"policy": "router", "allow": [], "deny": [], "tokens_per_day": 0},
  "sources": []
}
json.dump(base, open("data/sites/one/passport.json", "w"), ensure_ascii=False, indent=2)
PY

ok=0; fail=0
chk() { if [ "$1" = "0" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi }

# фейк-сайты разведки (18488 полный, 18489 минимальный) — на весь прогон
python3 tests/intake/fake_intake_site.py > "$FAKELOG" 2>&1 &
FAKE=$!
trap 'kill "$SRV" "$FAKE" "$MOCK" 2>/dev/null || true; rm -rf data/sites data/registry data/miniapp-static data/acc-accepted-passport.json; rm -f data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db data/checkpoints.db' EXIT

up=0
for _ in $(seq 1 40); do
  [ "$(curl -s "http://127.0.0.1:18488/health" || true)" = "ok" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "INTAKEAPI FAIL: фейк-сайт не поднялся"; tail -5 "$FAKELOG"; exit 1; }

# ── A.5.5, прогон 1: старт с one (без duty) — duty-tick не нужен ──
METALOGOS_HTTP_ALLOW_PRIVATE=1 "$ML" run tests/intakeapi/cron_run1.mlog > /tmp/acc-cron1.out 2>/tmp/acc-cron1.err
cat /tmp/acc-cron1.out /tmp/acc-cron1.err | grep -q "CRON1 dl07=1 duty=0"
chk "$?" "A.5.5 (1/2): старт без duty → deadlines-джоба one есть, duty-tick нет"

# ── «мерж»: паспорт сайта two попадает в зеркало (как деплой после PR) ──
mkdir -p data/sites/two
python3 - <<'PY'
import json
two = {
  "slug": "two", "name": "Второй", "url": "http://127.0.0.1:18488",
  "languages": ["ru"], "timezone": "Europe/Minsk",
  "people": {"approver_tg_env": "ACC_OWNER_TG_ID", "editor_tg_env": None, "expert_tg_env": None},
  "repo": {"github": None, "branch": "main", "deploy": "render_hook",
           "health_url": "http://127.0.0.1:18488/health", "key_envs": []},
  "checks": {"uptime_every_min": 5, "daily_at": "08:30",
             "pages": [{"path": "/", "expect_text": "Юридические услуги"}]},
  "modules": ["duty", "deadlines"],
  "limits": {"tokens_per_day": 0, "deploys_per_day": 0},
  "domain": {"registrar": None, "registrar_panel_url": None, "expires": None,
             "expires_source": "auto", "cert_expires": None, "autorenew": None,
             "dns_provider": None, "warn_days": [60, 30, 7], "renewal_owner": "owner"},
  "profile": "showcase", "participation": "pr_with_approval",
  "platform": {"adapter": "render", "cdn": None},
  "models": {"policy": "router", "allow": [], "deny": [], "tokens_per_day": 0},
  "sources": []
}
json.dump(two, open("data/sites/two/passport.json", "w"), ensure_ascii=False, indent=2)
PY

# ── A.5.5, прогон 2 (РЕСТАРТ приложения): код не менялся ──
METALOGOS_HTTP_ALLOW_PRIVATE=1 "$ML" run tests/intakeapi/cron_run2.mlog > /tmp/acc-cron2.out 2>/tmp/acc-cron2.err
cat /tmp/acc-cron2.out /tmp/acc-cron2.err > /tmp/acc-cron2.all || true
cat /tmp/acc-cron2.out || true
grep -q "CRON2 dl07=1 dl0830=1 duty=1" /tmp/acc-cron2.all
chk "$?" "A.5.5 (2/2): рестарт → duty-tick для нового slug + deadlines-джоба 08:30"
grep -q "two: duty" /tmp/acc-cron2.all
chk "$?" "A.5.5: немедленный тик Дежурного прошёл по новому slug"

# ── черновики + инициализация tfake (идемпотентно) ──
METALOGOS_HTTP_ALLOW_PRIVATE=1 "$ML" run tests/intakeapi/fixture.mlog > /tmp/acc-fixture.out 2>&1
grep -q "FIXTURE created created" /tmp/acc-fixture.out || grep -q "FIXTURE updated updated" /tmp/acc-fixture.out
chk "$?" "фикстуры: два черновика в intake_drafts"

# ── мок GitHub + serve (прод-значения env: interpreter, exec открыт нарядом) ──
: > "$MOCKLOG"
MOCK_LOG="$MOCKLOG" python3 tests/registryapi/mock_github.py > "$FAKELOG" 2>&1 &
MOCK=$!
up=0
for _ in $(seq 1 80); do
  [ "$(curl -s "http://127.0.0.1:$MOCKPORT/health" || true)" != "" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "INTAKEAPI FAIL: мок не поднялся"; tail -5 "$FAKELOG"; exit 1; }

METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_SESSION_SECRET,ACC_PUBLIC_URL,ACC_GITHUB_TOKEN,ACC_GITHUB_API_BASE,METALOGOS_HTTP_ALLOW_PRIVATE" \
METALOGOS_HTTP_ALLOW_PRIVATE=1 \
METALOGOS_ALLOW_EXEC=1 \
METALOGOS_SERVE_ALLOW_EXEC=1 \
METALOGOS_SERVE_BACKEND=interpreter \
ACC_SESSION_SECRET="$SECRET" \
ACC_PUBLIC_URL="https://acc-test.example" \
ACC_GITHUB_TOKEN="$TOKEN" \
ACC_GITHUB_API_BASE="http://127.0.0.1:$MOCKPORT" \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
up=0
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || true)"
  [ "$code" = "200" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "INTAKEAPI FAIL: сервер не поднялся"; tail -10 "$LOG"; exit 1; }

now="$(date +%s)"
TOK="$((now + 900)).$(printf 'acc-app:%s' "$((now + 900))" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')"

calls() { wc -l < "$MOCKLOG" | tr -d ' '; }

# без сессии → 401
r0="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/intake/drafts" || true)"
[ "$r0" = "401" ]; chk "$?" "0: /api/intake/drafts без сессии → 401"

# список черновиков
rL="$(curl -s -H "X-ACC-Session: $TOK" "http://127.0.0.1:$PORT/api/intake/drafts" || true)"
echo "$rL" | grep -q 'http://127.0.0.1:18488'
chk "$?" "список черновиков содержит url 18488"

# паспорт из формы: с ошибкой slug (A.5.1) и валидный (A.5.4)
PASSPORT_BAD='{"slug":"Bad Slug!","name":"ТЭГА","url":"https://acc-fake.example","languages":["ru"],"timezone":"Europe/Minsk","people":{"approver_tg_env":"ACC_OWNER_TG_ID","editor_tg_env":null,"expert_tg_env":null},"repo":{"github":"ShkodnikAI/tega","branch":"main","deploy":"render_hook","health_url":"https://acc-fake.example/health","key_envs":["SITE_ACC_FAKE_GITHUB_TOKEN"]},"checks":{"uptime_every_min":5,"daily_at":"07:00","pages":[{"path":"/","expect_text":"ТЭГА"}]},"modules":["duty","deadlines","secretary"],"limits":{"tokens_per_day":0,"deploys_per_day":0},"domain":{"registrar":null,"registrar_panel_url":null,"expires":null,"expires_source":"auto","cert_expires":null,"autorenew":null,"dns_provider":null,"warn_days":[60,30,7],"renewal_owner":"owner"},"profile":"showcase","participation":"pr_with_approval","platform":{"adapter":"render","cdn":null},"models":{"policy":"router","allow":[],"deny":[],"tokens_per_day":0},"sources":[]}'
PASSPORT_OK="$(python3 -c "
import json
p = json.loads('''$PASSPORT_BAD''')
p['slug'] = 'acc-fake'
print(json.dumps(p, ensure_ascii=False))
")"

ID1="$(python3 -c "import urllib.parse; print(urllib.parse.quote('http://127.0.0.1:18488', safe=''))")"
ID2="$(python3 -c "import urllib.parse; print(urllib.parse.quote('http://127.0.0.1:18489', safe=''))")"

# ── A.5.1: ошибка slug → ошибка у поля, PR не создаётся ──
rv1="$(curl -s -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d "{\"passport\":$PASSPORT_BAD}" "http://127.0.0.1:$PORT/api/intake/$ID1/validate" || true)"
echo "t1 validate: $rv1"
echo "$rv1" | grep -q '"ok":false'
chk "$?" "A.5.1: validate → ok:false"
echo "$rv1" | grep -q '"field":"slug"'
chk "$?" "A.5.1: ошибка у поля slug"
ra1="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d "{\"passport\":$PASSPORT_BAD,\"with_notes\":false}" "http://127.0.0.1:$PORT/api/intake/$ID1/accept" || true)"
[ "$ra1" = "400" ]; chk "$?" "A.5.1: accept с плохим slug → 400"
n1="$(calls)"; [ "$n1" = "0" ]; chk "$?" "A.5.1: мок GitHub не вызван (вызовов: $n1)"

# ── A.5.2: пробный прогон не пишет incidents/events ──
cnt() { python3 - "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect("data/sites/tfake/site.db")
t = sys.argv[1]
print(con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0])
PY
}
b_inc="$(cnt incidents)"; b_ev="$(cnt events)"; b_hc="$(cnt health_checks)"
sites_before="$(ls data/sites | sort | tr '\n' ' ')"
rt="$(curl -s -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" -d '{}' \
  "http://127.0.0.1:$PORT/api/intake/$ID1/trialrun" || true)"
echo "t2 trial: $rt"
echo "$rt" | grep -q '"green":true'
chk "$?" "A.5.2: прогон зелёный на фейковом сайте"
echo "$rt" | grep -q '"verdict":"ok"'
chk "$?" "A.5.2: страница ok в ответе"
echo "$rt" | grep -q '"health":{'
chk "$?" "A.5.2: health_url проверен"
a_inc="$(cnt incidents)"; a_ev="$(cnt events)"; a_hc="$(cnt health_checks)"
[ "$b_inc" = "$a_inc" ] && [ "$b_ev" = "$a_ev" ] && [ "$b_hc" = "$a_hc" ]
chk "$?" "A.5.2: счётчики incidents/events/health_checks не изменились ($b_inc/$b_ev/$b_hc → $a_inc/$a_ev/$a_hc)"
sites_after="$(ls data/sites | sort | tr '\n' ' ')"
[ "$sites_before" = "$sites_after" ]
chk "$?" "A.5.2: data/sites не пополнился (прогон не создаёт файл черновика-сайта)"

# ── A.5.3: «Принять» при красном прогоне без отметки → 400 ──
ra3="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d "{\"passport\":$PASSPORT_OK,\"with_notes\":false}" "http://127.0.0.1:$PORT/api/intake/$ID2/accept" || true)"
[ "$ra3" = "400" ]; chk "$?" "A.5.3: красный прогон без отметки → 400"
n3="$(calls)"; [ "$n3" = "0" ]; chk "$?" "A.5.3: мок GitHub не вызван (вызовов: $n3)"

# ── A.5.4: валидный паспорт → мок получил файл, проходящий ValidatePassport ──
ra4="$(curl -s -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d "{\"passport\":$PASSPORT_OK,\"with_notes\":false}" "http://127.0.0.1:$PORT/api/intake/$ID1/accept" || true)"
echo "t4 accept: $ra4"
echo "$ra4" | grep -q '"pr_url":"https://github.com/ShkodnikAI/fosved-acc/pull/42"'
chk "$?" "A.5.4: pr_url в ответе"
python3 - "$MOCKLOG" "$ROOT" <<'PY'
import json, sys, base64, os
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
paths = [r["path"] for r in recs]
keys = []
for r in recs:
    p = r["path"]
    if "/git/ref/heads/main" in p: keys.append("ref")
    elif "/git/commits/" in p: keys.append("base-commit")
    elif "/git/blobs" in p: keys.append("blob")
    elif "/git/trees" in p: keys.append("tree")
    elif "/git/commits" in p: keys.append("commit")
    elif "/git/refs" in p: keys.append("branch")
    elif "/pulls" in p: keys.append("pull")
assert keys == ["ref", "base-commit", "blob", "tree", "commit", "branch", "pull"], f"порядок вызовов: {keys}"
assert all(r["auth"] == "yes" for r in recs), "нет Authorization Bearer"
# ветка PR — под файл паспорта сайта
refs = next(r for r in recs if "/git/refs" in r["path"])
assert "sites-acc-fake-passport" in json.loads(refs["body"])["ref"], refs["body"]
# blob — файл sites/acc-fake/passport.json в base64
blob = next(r for r in recs if "/git/blobs" in r["path"])
body = json.loads(blob["body"])
assert body["encoding"] == "base64"
content = base64.b64decode(body["content"]).decode("utf-8")
tree = next(r for r in recs if "/git/trees" in r["path"])
assert "sites/acc-fake/passport.json" in tree["body"], tree["body"]
open(os.path.join(sys.argv[2], "data/acc-accepted-passport.json"), "w").write(content)
print("MOCK SEQUENCE OK: " + " → ".join(keys))
PY
chk "$?" "A.5.4: порядок и содержимое вызовов мока"
METALOGOS_HTTP_ALLOW_PRIVATE=1 "$ML" run tests/intakeapi/validate_one.mlog > /tmp/acc-validate1.out 2>/tmp/acc-validate1.err
cat /tmp/acc-validate1.out /tmp/acc-validate1.err | grep -q "ACCEPTED FILE VALID"
chk "$?" "A.5.4: файл из blob проходит ValidatePassport"

# черновик → статус pr_open и ссылка (A.4)
python3 - <<'PY'
import sqlite3
con = sqlite3.connect("data/acc.db")
row = con.execute("SELECT status, pr_url FROM intake_accepts WHERE url = 'http://127.0.0.1:18488'").fetchone()
assert row is not None, "нет записи intake_accepts"
assert row[0] == "pr_open", row
assert row[1] == "https://github.com/ShkodnikAI/fosved-acc/pull/42", row
print("INTAKE ACCEPTS OK: %s %s" % row)
PY
chk "$?" "A.5.4: черновик получил статус pr_open со ссылкой"
rl2="$(curl -s -H "X-ACC-Session: $TOK" "http://127.0.0.1:$PORT/api/intake/drafts" || true)"
echo "$rl2" | grep -q '"status":"pr_open"'
chk "$?" "A.4: список черновиков показывает pr_open"

# ── рендер вкладки (node) ──
node tests/intakeapi/dom_intake.js > /tmp/acc-intake-dom.out 2>&1
chk "$?" "рендер вкладки «Приём» (node)"
grep -q "DOM INTAKE OK" /tmp/acc-intake-dom.out
chk "$?"

# ── токен не утекает в логи ──
if grep -qF "$TOKEN" "$MOCKLOG" "$LOG" /tmp/acc-cron1.out /tmp/acc-cron2.out /tmp/acc-validate1.out 2>/dev/null; then
  fail=$((fail+1)); echo "FAIL: токен в логах"
else
  ok=$((ok+1))
fi

if [ "$fail" = 0 ]; then
  echo "INTAKEAPI OK 6/6"
  exit 0
fi
echo "INTAKEAPI FAIL (ok=$ok fail=$fail)"
tail -20 "$LOG"
exit 1
