#!/usr/bin/env bash
# Тесты реестров через Mini App (наряд АСС-2.4, A.3) против настоящего
# mlog serve app.mlog с МОКОМ GitHub (tests/registryapi/mock_github.py):
#   1. неверная запись (id с пробелом) → 400, мок не вызван;
#   2. запись со значением, похожим на ключ (sk-…) → 400;
#   3. валидное добавление → 200 {pr_url}, мок получил вызовы Git Data API
#      в нужном порядке, blob содержит base64 нового текста с записью;
#   4. пустой ACC_GITHUB_TOKEN → понятная ошибка, мок не вызван;
#   5. в выводе теста нет значения токена (grep).
# Юниты валидатора — tests/registry/validate.mlog (шаг CI).
# Запуск из корня репо: bash tests/registryapi/run.sh [путь к mlog]
# Ожидаемо: REGISTRYAPI OK 5/5
set -uo pipefail

ML="${1:-mlog}"
PORT=10000
MOCKPORT=18477
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_regapi.XXXXXX.log)"
MOCKLOG="$(mktemp /tmp/acc_mock_gh.XXXXXX.jsonl)"
FAKELOG="$(mktemp /tmp/acc_regapi_mock.XXXXXX.log)"
TOKEN="acc-ui-test-token-0123456789"

cd "$ROOT"
# чистое окружение (тестовая гигиена)
for f in data/acc.db data/memory.db; do
  if [ -e "$f" ]; then
    echo "REGISTRYAPI FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done
if [ -e data/registry ]; then
  echo "REGISTRYAPI FAIL: data/registry уже существует"; exit 1
fi
mkdir -p data/registry data/miniapp-static data/sites/journal
cp modules/miniapp/static/app.html modules/miniapp/static/app.js modules/miniapp/static/app.css data/miniapp-static/
# фикстура реестра (канонический формат, как в репо после реформата)
cat > data/registry/sources.json <<'EOS'
[
{"domain":"data.iana.org","frequency":"weekly","id":"rdap-iana","kind":"registry","read_method":"http","status":"active","terms_checked":true},
{"domain":"whois.cctld.by","frequency":"weekly","id":"whois-cctld-by","kind":"registry","read_method":"whois","status":"active","terms_checked":true},
{"domain":"api.github.com","frequency":"on-demand","id":"github-api","kind":"registry","read_method":"http","status":"active","terms_checked":true}
]
EOS
cat > data/registry/models.json <<'EOS'
[]
EOS

: > "$MOCKLOG"
MOCK_LOG="$MOCKLOG" python3 tests/registryapi/mock_github.py > "$FAKELOG" 2>&1 &
MOCK=$!
METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_SESSION_SECRET,ACC_PUBLIC_URL,ACC_GITHUB_TOKEN,ACC_GITHUB_API_BASE,METALOGOS_HTTP_ALLOW_PRIVATE" \
METALOGOS_HTTP_ALLOW_PRIVATE=1 \
ACC_SESSION_SECRET="acc-reg-test-secret" \
ACC_PUBLIC_URL="https://acc-test.example" \
ACC_GITHUB_TOKEN="$TOKEN" \
ACC_GITHUB_API_BASE="http://127.0.0.1:$MOCKPORT" \
METALOGOS_SERVE_ALLOW_EXEC=1 \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" "$MOCK" 2>/dev/null || true; rm -rf data/registry data/miniapp-static data/sites/journal; rm -f data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db data/checkpoints.db' EXIT

up=0
for _ in $(seq 1 80); do
  [ "$(curl -s "http://127.0.0.1:$MOCKPORT/health" || true)" != "" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "REGISTRYAPI FAIL: мок не поднялся"; tail -5 "$FAKELOG"; exit 1; }
up=0
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || true)"
  [ "$code" = "200" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "REGISTRYAPI FAIL: сервер не поднялся"; tail -10 "$LOG"; exit 1; }

now="$(date +%s)"
TOK="$((now + 900)).$(printf 'acc-app:%s' "$((now + 900))" | openssl dgst -sha256 -hmac "acc-reg-test-secret" | awk '{print $NF}')"

ok=0; fail=0
chk() { if [ "$1" = "0" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi }

calls() { wc -l < "$MOCKLOG" | tr -d ' '; }

# ── тест 1: неверная запись (id с пробелом) → 400, мок не вызван
r1="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d '{"op":"add","entry":{"id":"bad id","kind":"registry","domain":"x.example","read_method":"http","frequency":"weekly","terms_checked":true,"status":"active"}}' \
  "http://127.0.0.1:$PORT/api/registry/sources" || true)"
echo "t1: $r1"
[ "$r1" = "400" ]; chk "$?" "1: неверный id → 400"
n1="$(calls)"; [ "$n1" = "0" ]; chk "$?" "1: мок не вызван (вызовов: $n1)"

# ── тест 2: значение, похожее на ключ (sk-…) → 400 (правило 8)
r2="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d '{"op":"add","entry":{"id":"leaky","kind":"registry","domain":"x.example","read_method":"http","frequency":"weekly","terms_checked":true,"status":"active","note":"sk-abcdef123456"}}' \
  "http://127.0.0.1:$PORT/api/registry/sources" || true)"
echo "t2: $r2"
[ "$r2" = "400" ]; chk "$?" "2: sk-… → 400 (правило 8)"
n2="$(calls)"; [ "$n2" = "0" ]; chk "$?" "2: мок не вызван (вызовов: $n2)"

# ── тест 3: валидное добавление → 200 {pr_url}, порядок вызовов Git Data API
r3="$(curl -s -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d '{"op":"add","entry":{"id":"new-src","kind":"registry","domain":"new.example","read_method":"http","frequency":"weekly","terms_checked":true,"status":"active"}}' \
  "http://127.0.0.1:$PORT/api/registry/sources" || true)"
echo "pr: $r3"
echo "$r3" | grep -q '"pr_url":"https://github.com/ShkodnikAI/fosved-acc/pull/42"'
chk "$?" "3: pr_url в ответе"
# порядок: ref/heads/main → commits → blobs → trees → commits → refs → pulls
python3 - "$MOCKLOG" <<'PY'
import json, sys, base64
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
paths = [r["path"] for r in recs]
def has(sub): return any(sub in p for p in paths)
seq = [
    has("/git/ref/heads/main"),
    has("/git/commits/"),
    has("/git/blobs"),
    has("/git/trees"),
    sum(1 for p in paths if "/git/commits" in p) >= 1,
    has("/git/refs"),
    has("/pulls"),
]
order = [i for i, p in enumerate(paths) if True]
# фактический порядок ключевых шагов
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
expected = ["ref", "base-commit", "blob", "tree", "commit", "branch", "pull"]
assert keys == expected, f"порядок вызовов: {keys}"
# все вызовы с Bearer
assert all(r["auth"] == "yes" for r in recs), "нет Authorization Bearer в вызовах"
# blob содержит base64 нового текста с новой записью
blob = next(r for r in recs if "/git/blobs" in r["path"])
blob_body = json.loads(blob["body"])
content = base64.b64decode(blob_body["content"]).decode("utf-8")
assert '"id":"new-src"' in content, "новой записи нет в blob"
assert blob_body["encoding"] == "base64", "encoding не base64"
print("MOCK SEQUENCE OK: " + " → ".join(keys))
PY
chk "$?" "3: порядок/содержимое вызовов мока"

# ── тест 4: пустой ACC_GITHUB_TOKEN → понятная ошибка, мок не вызван
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null || true
n_before="$(calls)"
METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_SESSION_SECRET,ACC_PUBLIC_URL,ACC_GITHUB_API_BASE,METALOGOS_HTTP_ALLOW_PRIVATE" \
METALOGOS_HTTP_ALLOW_PRIVATE=1 \
ACC_SESSION_SECRET="acc-reg-test-secret" \
ACC_PUBLIC_URL="https://acc-test.example" \
ACC_GITHUB_API_BASE="http://127.0.0.1:$MOCKPORT" \
METALOGOS_SERVE_ALLOW_EXEC=1 \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
up=0
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" || true)"
  [ "$code" = "200" ] && up=1 && break
  sleep 0.25
done
[ "$up" = "1" ] || { echo "REGISTRYAPI FAIL: второй сервер не поднялся"; exit 1; }
r4="$(curl -s -X POST -H "X-ACC-Session: $TOK" -H "Content-Type: application/json" \
  -d '{"op":"add","entry":{"id":"another","kind":"registry","domain":"y.example","read_method":"http","frequency":"weekly","terms_checked":true,"status":"active"}}' \
  "http://127.0.0.1:$PORT/api/registry/sources" || true)"
echo "no-token: $r4"
echo "$r4" | grep -q "ACC_GITHUB_TOKEN"
chk "$?" "4: понятная ошибка про ACC_GITHUB_TOKEN"
n4="$(calls)"; [ "$n4" = "$n_before" ]; chk "$?" "4: мок не вызван (было $n_before, стало $n4)"

# ── тест 5: в выводе теста нет значения токена
if grep -qF "$TOKEN" "$MOCKLOG" "$LOG" /tmp/sitesapi-unit.out 2>/dev/null; then
  fail=$((fail+1)); echo "FAIL: 5: токен в логах"
else
  ok=$((ok+1))
fi

if [ "$fail" = 0 ]; then
  echo "REGISTRYAPI OK 5/5"
  exit 0
fi
echo "REGISTRYAPI FAIL (ok=$ok fail=$fail)"
tail -10 "$LOG"
exit 1
