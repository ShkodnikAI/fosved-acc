#!/usr/bin/env bash
# Полигон Дежурного (наряд АСС-1.3, A.4): фейк-сайт + прогон сценариев.
# METALOGOS_HTTP_ALLOW_PRIVATE=1 — ТОЛЬКО здесь (тест), не в Dockerfile/проде.
#
# Запуск из корня репо: bash tests/polygon/duty/run.sh [путь к mlog]
# Ожидаемо: POLYGON duty 5/5
set -uo pipefail

ML="${1:-mlog}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LOG="$(mktemp /tmp/acc_fake_site.XXXXXX.log)"

cd "$ROOT"
mkdir -p data/sites/pfake
# фикстурная БД — свежая на прогон (тестовая гигиена; продуктовый код
# удалений не содержит — ТЗ §11)
rm -f data/sites/pfake/site.db

python3 tests/polygon/duty/fake_site.py > "$LOG" 2>&1 &
FAKE=$!
trap 'kill "$FAKE" 2>/dev/null || true' EXIT

up=0
for _ in $(seq 1 40); do
  body="$(curl -s "http://127.0.0.1:18455/health" || true)"
  if [ "$body" = "ok" ]; then up=1; break; fi
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "POLYGON duty FAIL: фейк-сайт не поднялся"; tail -5 "$LOG"; exit 1
fi

set -o pipefail
METALOGOS_HTTP_ALLOW_PRIVATE=1 "$ML" run tests/polygon/duty/run.mlog 2>"$(dirname "$LOG")/acc_polygon.err"
status=$?
grep -v REDACT "$(dirname "$LOG")/acc_polygon.err" | grep "\[try\]\|error" | head -5 || true
exit $status
