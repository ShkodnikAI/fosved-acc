#!/usr/bin/env bash
# A.2 наряда АСС-1.2: живучесть ATTACH при mlog serve.
# 50 последовательных и 20 параллельных (xargs -P 10) запросов на запись,
# затем чтение итога и проверка громкой ошибки на плохом slug.
#
# Запуск из корня репо: bash tests/store/serve_attach.sh [путь к mlog]
# Ожидаемо: ATTACH OK sequential=50/50 parallel=20/20 count=70 bad=500
set -uo pipefail

ML="${1:-mlog}"
PORT=18441
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_serve_attach.XXXXXX.log)"

cd "$ROOT"
mkdir -p data/sites/t1

"$ML" serve tests/store/serve_app.mlog > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true' EXIT

# ждём готовности сервера (до 15 с)
up=0
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/r" || true)"
  if [ "$code" != "000" ]; then up=1; break; fi
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "ATTACH FAIL сервер не поднялся"; tail -5 "$LOG"; exit 1
fi

# 50 последовательных записей
seq_ok=0
for _ in $(seq 1 50); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/w" || true)"
  [ "$code" = "200" ] && seq_ok=$((seq_ok + 1))
done

# 20 параллельных записей (xargs -P 10)
par_ok="$(seq 1 20 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$PORT/w" | grep -c '^200$' || true)"

# данные на месте
final="$(curl -s "http://127.0.0.1:$PORT/r" || true)"
# плохой slug — громкая ошибка → 500
bad="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/bad" || true)"

echo "sequential=${seq_ok}/50 parallel=${par_ok}/20 final=${final} bad=${bad}"
if [ "$seq_ok" = "50" ] && [ "$par_ok" = "20" ] && [ "$final" = "count=70" ] && [ "$bad" = "500" ]; then
  echo "ATTACH OK"
  exit 0
fi
echo "ATTACH FAIL"; tail -10 "$LOG"
exit 1
