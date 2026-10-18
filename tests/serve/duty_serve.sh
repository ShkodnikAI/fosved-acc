#!/usr/bin/env bash
# A.2 наряда АСС-1.7: сценарий 2 полигона Дежурного под НАСТОЯЩИМ mlog serve.
#
# Полигоны гоняются через mlog run (интерпретатор) и ошибку Metalogos-#1336
# не видят. Этот тест поднимает mlog serve app.mlog (продовое приложение) с
# тем же окружением, что в Dockerfile, на тестовом паспорте pfav с фейковым
# сайтом 127.0.0.1. Сценарий 2: /p2 отвечает 500 дважды подряд (цикл +
# подтверждение через 60 с) → в incidents ОДНА строка down. Запуск цикла —
# через существующий внутренний маршрут /internal/duty/bootstrap.
#
# METALOGOS_HTTP_ALLOW_PRIVATE=1 — ТОЛЬКО здесь (тест), не в Dockerfile/проде.
#
# Запуск из корня репо:
#   bash tests/serve/duty_serve.sh [путь к mlog] [interpreter|vm]
# Ожидаемо:
#   interpreter → SERVE duty OK (блокирующий CI-шаг)
#   vm          → SERVE duty FAIL (Metalogos-#1336: each внутри if молчит;
#                 информационный CI-шаг, сигнал к возврату на VM — ADR-0003)
set -uo pipefail

ML="${1:-mlog}"
BACKEND="${2:-interpreter}"
PORT=10000
FAKEPORT=18456
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_serve_duty.XXXXXX.log)"
FAKELOG="$(mktemp /tmp/acc_serve_fake.XXXXXX.log)"

cd "$ROOT"

# ── тестовая гигиена: продовый data/ должен быть чист (CI — свежий чекаут)
for f in data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db; do
  if [ -e "$f" ]; then
    echo "SERVE duty FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done
mkdir -p data/sites/pfav
cp tests/serve/passport.json data/sites/pfav/passport.json

python3 tests/serve/fake_site.py > "$FAKELOG" 2>&1 &
FAKE=$!
# allowlist — имена из runbook §2 (в проде ACC_HEARTBEAT_URL задан; здесь
# значение пустое → heartbeat обязан вернуть skip, имя только разрешено).
# Тестовый токен — литерал (прецедент: tests/polygon/secretary/run.sh).
METALOGOS_SERVE_BACKEND="$BACKEND" \
METALOGOS_ALLOW_EXEC=1 \
METALOGOS_SERVE_ALLOW_EXEC=1 \
METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_HEARTBEAT_URL" \
ACC_INTERNAL_TOKEN="poly-internal-token" \
METALOGOS_HTTP_ALLOW_PRIVATE=1 \
"$ML" serve app.mlog > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" "$FAKE" 2>/dev/null || true; rm -rf data/sites/pfav; rm -f data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db' EXIT

# ── ждём готовности фейк-сайта и сервера
up=0
for _ in $(seq 1 40); do
  [ "$(curl -s "http://127.0.0.1:$FAKEPORT/health" || true)" = "ok" ] && up=1 && break
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "SERVE duty FAIL: фейк-сайт не поднялся"; tail -5 "$FAKELOG"; exit 1
fi
up=0
for _ in $(seq 1 80); do
  body="$(curl -s "http://127.0.0.1:$PORT/health" || true)"
  case "$body" in *'"status":"ok"'*) up=1; break;; esac
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "SERVE duty FAIL: сервер не поднялся (backend=$BACKEND)"; tail -10 "$LOG"; exit 1
fi
echo "backend=$BACKEND: /health ok"

# ── сценарий 2: один вызов маршрута = цикл + подтверждение (sleep 60) +
#    повторная проверка + инцидент. Таймаут с запасом под sleep(60).
BOOT="$(curl -s --max-time 150 "http://127.0.0.1:$PORT/internal/duty/bootstrap?token=poly-internal-token" || true)"
echo "bootstrap: $BOOT"

# ── критерий: в incidents одна строка down (открытая) — прямая проверка БД.
# Таблицы сайта — в data/sites/<slug>/site.db (core/store.mlog: ATTACH AS
# site_<slug>); сам файл и есть «incidents» БД сайта.
RES="$(python3 - <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect("data/sites/pfav/site.db")
    total = con.execute("SELECT COUNT(*) FROM incidents WHERE kind='down'").fetchone()[0]
    opened = con.execute("SELECT COUNT(*) FROM incidents WHERE kind='down' AND closed_ts IS NULL").fetchone()[0]
    print(f"incidents down: total={total} opened={opened}")
    sys.exit(0 if (total == 1 and opened == 1) else 1)
except sqlite3.Error as e:
    print(f"incidents down: БД недоступна: {e}")
    sys.exit(1)
PY
)"
echo "$RES"
echo "$RES" | grep -q "total=1 opened=1"
DB_OK=$?
# отчёт маршрута подтверждает открытие инцидента циклом (opened=1)
echo "$BOOT" | grep -q "opened=1"
REP_OK=$?

if [ "$DB_OK" = "0" ] && [ "$REP_OK" = "0" ]; then
  echo "SERVE duty OK (backend=$BACKEND): сбой 500 дважды подряд → 1 строка down в incidents"
  exit 0
fi
echo "SERVE duty FAIL (backend=$BACKEND): ожидалась 1 строка down в incidents и opened=1 в отчёте"
tail -10 "$LOG"
exit 1
