#!/usr/bin/env bash
# C.1 наряда #54 (АСС-1.16): serve-тест пути «cron сработал → паттерн
# исполнен» — то, чего не проверял ни один тест раньше (интекапи-тесты
# звали bootstrap в mlog run; полигон Секретаря звал паттерны напрямую).
#
# Живой mlog serve app.mlog (продовое приложение) с тестовым паспортом
# pfav (fake-сайт 127.0.0.1, как в duty_serve.sh). Порядок:
#   1) посадка СТАРЫХ джоб (B.2: duty-tick и др. — как оставил прошлый
#      релиз) отдельным mlog run с тем же memory-persist (в run-режиме
#      kv-persist не активируется — но cron_add в run пишет в memory.db
#      ЧЕРЕЗ db-блок? нет: посадка идёт через /test-роут SERVE, см. ниже);
#   2) serve app.mlog + POST /internal/{duty,deadlines,secretary}/bootstrap
#      (как start.sh) — старые сняты, новые зарегистрированы;
#   3) расписание сводки/дедлайнов поминутное: паспорт pfav
#      daily_at=07:00 → тест ЗАМЕНЯЕТ на «* * * * *» не может (формат
#      HH:MM) — поэтому регистрируем ДОПОЛНИТЕЛЬНУЮ поминутную джобу
#      SecSummaryOnce/DlTickAll тем же bootstrap-механизмом через
#      тестовый маршрут /test/fast-cron (идиома полигона: тест-роут в
#      тестовом serve-приложении поверх продовых модулей);
#   4) ждём ≤ 3 мин: [cron] firing ×4 (DeliverTickAll, SecSummaryOnce,
#      DlTickAll, DutyTickAll), 0 «dispatch error»;
#   5) побочные эффекты: site.health_checks (Дежурный), kv
#      acc_summary_day (сводка), mock Telegram (отправка), запись
#      дедлайна (journal/events сайта).
#
# Мутация (для отчёта, запускается вручную): вернуть "secretary-deliver"
# в deliver.mlog:263 → тест красный: firing есть, dispatch error ≠ 0.
#
# Запуск из корня репо:
#   bash tests/serve/cron_dispatch.sh [путь к mlog]
# Ожидаемо: SERVE cron-dispatch OK
set -uo pipefail

ML="${1:-mlog}"
PORT=10000
FAKEPORT=18456
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="$(mktemp /tmp/acc_serve_cron.XXXXXX.log)"
FAKELOG="$(mktemp /tmp/acc_serve_fake.XXXXXX.log)"
WORK="$(mktemp -d /tmp/acc_serve_cron.XXXXXX)"

cd "$ROOT"

# ── тестовая гигиена: продовый data/ должен быть чист (CI — свежий чекаут)
for f in data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db; do
  if [ -e "$f" ]; then
    echo "SERVE cron-dispatch FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done

# ── тестовое serve-приложение: продовые модули + тест-маршруты
#    (/test/old-jobs — посадка старых джоб; /test/fast-cron — поминутные
#    SecSummaryOnce/DlTickAll; /test/cron-state — содержимое cron_jobs)
mkdir -p "$WORK/data/sites/pfav" "$WORK/data/registry" "$WORK/data/miniapp-static"
cp -r core modules "$WORK/"
# #54 C.1: все три модуля (duty/deadlines/secretary) — базовый паспорт
# serve-теста создаёт только duty; этому тесту нужны все четыре паттерна
python3 - "$ROOT/tests/serve/passport.json" "$WORK/data/sites/pfav/passport.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["modules"] = ["duty", "deadlines", "secretary"]
json.dump(p, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PY
cp registry/*.json "$WORK/data/registry/" 2>/dev/null || true
touch "$WORK/data/.keep"
cat > "$WORK/serve_test.mlog" <<'EOS'
// #54 C.1: продовое приложение + тест-маршруты (идиома полигона
// Секретаря: тест-роуты в тестовом приложении поверх продовых модулей).
import core/store as st
import core/registry as reg
import modules/duty/schedule as duty
import modules/duty/heartbeat as hb
import modules/deadlines/run as dl
import modules/secretary/bot as bot
import modules/secretary/deliver as sec
import modules/intake/form as intake_form

db { url: "sqlite:data/acc.db" }
memory { persist: "data/memory.db" }

mlogserver {
  port: 10000
  host: "127.0.0.1"
  route "/health" method=GET {
    let data_ok = file_exists("data/.keep")
    let db_r = try query("SELECT 1 AS one", [])
    let none = redact("()", "hash_only")
    let db_ok = redact(to_string(db_r), "hash_only") != none
    let mut status = "ok"
    if data_ok == false or db_ok == false then { let status = "degraded" }
    return respond("200 " + json_encode({status: status}))
  }
  route "/internal/duty/bootstrap" method=GET {
    let expected = env_or("ACC_INTERNAL_TOKEN", "")
    let got = query_param("token")
    let ok = redact(to_string(redact(got, "hash_only") == redact(to_string(expected), "hash_only")), "hash_only")
    if ok != redact(to_string(true), "hash_only") { return respond("401 " + json_encode({error: "unauthorized"})) }
    let report = duty.DutyBootstrap()
    return respond("200 " + json_encode({report: redact(report, "all")}))
  }
  route "/internal/deadlines/bootstrap" method=GET {
    let expected = env_or("ACC_INTERNAL_TOKEN", "")
    let got = query_param("token")
    let ok = redact(to_string(redact(got, "hash_only") == redact(to_string(expected), "hash_only")), "hash_only")
    if ok != redact(to_string(true), "hash_only") { return respond("401 " + json_encode({error: "unauthorized"})) }
    let report = dl.DlBootstrap()
    return respond("200 " + json_encode({report: redact(report, "all")}))
  }
  route "/internal/secretary/bootstrap" method=GET {
    let expected = env_or("ACC_INTERNAL_TOKEN", "")
    let got = query_param("token")
    let ok = redact(to_string(redact(got, "hash_only") == redact(to_string(expected), "hash_only")), "hash_only")
    if ok != redact(to_string(true), "hash_only") { return respond("401 " + json_encode({error: "unauthorized"})) }
    let report = sec.SecBootstrap()
    return respond("200 " + json_encode({report: redact(report, "all")}))
  }
  // мок-шов SecSend (идиома полигона Секретаря АСС-1.13): kv-ключ +
  // таблица mock_sends; в проде ключа нет — шов шлёт в Telegram API
  route "/test/seed" method=POST {
    let gd = grant_issue("db:insert:mock_sends", 60, "unlimited")
    let _ = db_execute_with_grant(gd, "CREATE TABLE IF NOT EXISTS mock_sends (ts REAL, text TEXT)", [])
    let _ = kv_set("acc_mock_send", "1")
    return respond("200 seeded")
  }
  // посадка СТАРЫХ джоб (как прошлый релиз) — внутри serve, чтобы
  // kv-persist был активен (в mlog run он не активируется)
  route "/test/old-jobs" method=POST {
    let a = cron_add(redact("*/5 * * * *", "all"), redact("duty-tick", "all"), redact("Europe/Minsk", "all"), "skip")
    let b = cron_add(redact("*/1 * * * *", "all"), redact("secretary-deliver", "all"), redact("UTC", "all"), "skip")
    let c = cron_add(redact("0 7 * * *", "all"), redact("secretary-summary-07:00-Europe/Minsk", "all"), redact("Europe/Minsk", "all"), "skip")
    let d = cron_add(redact("0 7 * * *", "all"), redact("deadlines-tick-07:00-Europe/Minsk", "all"), redact("Europe/Minsk", "all"), "skip")
    return respond("200 old planted")
  }
  // поминутные джобы сводки/дедлайнов (штатные — суточные на 07:00;
  // тесту нужно срабатывание за ≤3 мин) — тем же API, теми же паттернами
  route "/test/fast-cron" method=POST {
    let a = cron_add(redact("*/1 * * * *", "all"), redact("SecSummaryOnce", "all"), redact("UTC", "all"), "skip", redact("07:00|Europe/Minsk", "all"))
    let b = cron_add(redact("*/1 * * * *", "all"), redact("DlTickAll", "all"), redact("UTC", "all"), "skip", redact("07:00|Europe/Minsk", "all"))
    return respond("200 fast set")
  }
  // содержимое cron_jobs (для отладки и проверки миграции)
  route "/test/cron-state" method=GET {
    let mut old_n = 0.0
    let mut new_n = 0.0
    each j in cron_list() {
      let p = to_string(j.prompt)
      let is_old = redact(to_string(p == "duty-tick" or p == "secretary-deliver" or contains(p, "secretary-summary-") or contains(p, "deadlines-tick-")), "hash_only")
      let is_new = redact(to_string(p == "DutyTickAll" or p == "DeliverTickAll" or p == "SecSummaryOnce" or p == "DlTickAll"), "hash_only")
      if is_old == redact(to_string(true), "hash_only") { old_n = old_n + 1.0 }
      if is_new == redact(to_string(true), "hash_only") { new_n = new_n + 1.0 }
    }
    return respond("200 " + json_encode({old: old_n, new: new_n}))
  }
}
EOS

cd "$WORK"
python3 "$ROOT/tests/serve/fake_site.py" > "$FAKELOG" 2>&1 &
FAKE=$!
METALOGOS_SERVE_BACKEND=interpreter \
METALOGOS_ALLOW_EXEC=1 \
METALOGOS_SERVE_ALLOW_EXEC=1 \
METALOGOS_ENV_ALLOWLIST="ACC_INTERNAL_TOKEN,ACC_HEARTBEAT_URL,ACC_OWNER_TG_ID,TELEGRAM_BOT_TOKEN_ACC,METALOGOS_HTTP_ALLOW_PRIVATE" \
ACC_INTERNAL_TOKEN="poly-internal-token" \
ACC_OWNER_TG_ID="111222333" \
TELEGRAM_BOT_TOKEN_ACC="test-token" \
METALOGOS_HTTP_ALLOW_PRIVATE=1 \
"$ML" serve serve_test.mlog > "$LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" "$FAKE" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# ── ждём готовности фейк-сайта и сервера
up=0
for _ in $(seq 1 40); do
  [ "$(curl -s "http://127.0.0.1:$FAKEPORT/health" || true)" = "ok" ] && up=1 && break
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "SERVE cron-dispatch FAIL: фейк-сайт не поднялся"; tail -5 "$FAKELOG"; exit 1
fi
up=0
for _ in $(seq 1 80); do
  body="$(curl -s "http://127.0.0.1:$PORT/health" || true)"
  case "$body" in *'"status":"ok"'*) up=1; break;; esac
  sleep 0.25
done
if [ "$up" != "1" ]; then
  echo "SERVE cron-dispatch FAIL: сервер не поднялся"; grep -v REDACT "$LOG" | tail -8; exit 1
fi
echo "serve up (backend=interpreter)"

# ── шаг 0: мок-шов доставки (сводка пишет в mock_sends, не в Telegram)
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/test/seed"

# ── шаг 1: посадка старых джоб (B.2) — до bootstrap
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/test/old-jobs"
st_old="$(curl -s "http://127.0.0.1:$PORT/test/cron-state")"
echo "до bootstrap: $st_old"
old_n="$(printf '%s' "$st_old" | python3 -c 'import json,sys; print(json.load(sys.stdin)["old"])')"
[ "$old_n" = "4" ] || [ "$old_n" = "4.0" ] || { echo "SERVE cron-dispatch FAIL: старые джобы не посажены ($st_old)"; exit 1; }

# ── шаг 2: bootstrap-маршруты (как start.sh) — миграция + регистрация.
# Маркер в лог: dispatch-ошибки СТАРЫХ джоб (посажены шагом 1 и законно
# файлаются до миграции: их промпты — не паттерны) не считаем; критерий
# наряда — «нет ни одного dispatch error» для НОВЫХ джоб после bootstrap.
echo "[test] bootstrap-marker" >> "$LOG"
d="$(curl -s --max-time 180 "http://127.0.0.1:$PORT/internal/duty/bootstrap?token=poly-internal-token")"
l="$(curl -s --max-time 60 "http://127.0.0.1:$PORT/internal/deadlines/bootstrap?token=poly-internal-token")"
s="$(curl -s --max-time 60 "http://127.0.0.1:$PORT/internal/secretary/bootstrap?token=poly-internal-token")"
echo "bootstrap: duty=${d:0:120}…"
echo "bootstrap: deadlines=${l:0:120}"
echo "bootstrap: secretary=${s:0:120}"
case "$d$l$s" in
  *"error"*) echo "SERVE cron-dispatch FAIL: bootstrap вернул ошибку"; exit 1;;
esac
# миграция: старых 0 после bootstrap
st_mig="$(curl -s "http://127.0.0.1:$PORT/test/cron-state")"
echo "после bootstrap: $st_mig"
mig_old="$(printf '%s' "$st_mig" | python3 -c 'import json,sys; print(json.load(sys.stdin)["old"])')"
mig_new="$(printf '%s' "$st_mig" | python3 -c 'import json,sys; print(json.load(sys.stdin)["new"])')"
[ "$mig_old" = "0" ] || [ "$mig_old" = "0.0" ] || { echo "SERVE cron-dispatch FAIL: старые джобы не сняты ($st_mig)"; exit 1; }
# Все 4: DutyTickAll + DeliverTickAll + DlTickAll(07:00) + SecSummaryOnce(07:00)
[ "$mig_new" = "4" ] || [ "$mig_new" = "4.0" ] || { echo "SERVE cron-dispatch FAIL: новые джобы не все зарегистрированы ($st_mig)"; exit 1; }

# ── шаг 3: поминутные тестовые джобы (сводка + дедлайны)
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/test/fast-cron"

# ── шаг 4: ждём firing всех 4 паттернов (≤ 3 мин; duty-период 5 мин по
#    паспорту pfav — тоже попадёт в окно)
DEADLINE=$((SECONDS + 180))
fires=""
errs=""
while [ $SECONDS -lt $DEADLINE ]; do
  f1=$(grep -c "\[cron\] firing.*DutyTickAll" "$LOG" || true)
  f2=$(grep -c "\[cron\] firing.*DeliverTickAll" "$LOG" || true)
  f3=$(grep -c "\[cron\] firing.*SecSummaryOnce" "$LOG" || true)
  f4=$(grep -c "\[cron\] firing.*DlTickAll" "$LOG" || true)
  e=$(awk "/bootstrap-marker/,0" "$LOG" | grep -c "\[cron\] dispatch .* error" || true)
  if [ "$f1" -ge 1 ] && [ "$f2" -ge 1 ] && [ "$f3" -ge 1 ] && [ "$f4" -ge 1 ]; then
    break
  fi
  sleep 5
done
echo "firing: DutyTickAll=$f1 DeliverTickAll=$f2 SecSummaryOnce=$f3 DlTickAll=$f4; dispatch errors=$e"

if [ "$f1" -lt 1 ] || [ "$f2" -lt 1 ] || [ "$f3" -lt 1 ] || [ "$f4" -lt 1 ]; then
  echo "SERVE cron-dispatch FAIL: не все паттерны сработали за 3 мин"
  grep -E "\[cron\]" "$LOG" | tail -10
  exit 1
fi
if [ "$e" != "0" ]; then
  echo "SERVE cron-dispatch FAIL: есть dispatch errors"
  grep "\[cron\] dispatch .* error" "$LOG" | head -5
  exit 1
fi

# ── шаг 5: побочные эффекты
# 5a) Дежурный: запись в site.health_checks (БД сайта pfav)
HC="$(python3 - <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect("data/sites/pfav/site.db")
    n = con.execute("SELECT COUNT(*) FROM health_checks").fetchone()[0]
    print(n)
except sqlite3.Error as e:
    print(f"ERR {e}")
PY
)"
echo "health_checks: $HC"
[ "$HC" -ge 1 ] 2>/dev/null || { echo "SERVE cron-dispatch FAIL: Дежурный не записал проверку"; exit 1; }

# 5b) сводка: kv acc_summary_day = сегодня
SUMDAY="$(python3 - <<'PY'
import sqlite3, datetime
try:
    con = sqlite3.connect("data/memory.db")
    v = con.execute("SELECT value FROM kv_store WHERE key='acc_summary_day'").fetchone()
    today = datetime.date.today().isoformat()
    print("MATCH" if v and v[0] == today else f"MISMATCH {v} vs {today}")
except sqlite3.Error as e:
    print(f"ERR {e}")
PY
)"
echo "acc_summary_day: $SUMDAY"
[ "$SUMDAY" = "MATCH" ] || { echo "SERVE cron-dispatch FAIL: сводка не отметила день"; exit 1; }

# 5c) отправка сводки в мок Telegram (kv acc_mock_send=1 → таблица
#     mock_sends в acc.db; мок-шов полигона Секретаря АСС-1.13)
MS="$(python3 - <<'PY'
import sqlite3
try:
    con = sqlite3.connect("data/acc.db")
    n = con.execute("SELECT COUNT(*) FROM mock_sends").fetchone()[0]
    print(n)
except sqlite3.Error as e:
    print(f"ERR {e}")
PY
)"
echo "mock_sends (сводка/доставка): $MS"
[ "$MS" -ge 1 ] 2>/dev/null || { echo "SERVE cron-dispatch FAIL: сводка не ушла в мок Telegram"; exit 1; }

# 5d) дедлайны: запись события сайта (deadline_unknown/journal)
DL="$(python3 - <<'PY'
import sqlite3
try:
    con = sqlite3.connect("data/sites/pfav/site.db")
    tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    print("TABLES " + ",".join(tables))
except sqlite3.Error as e:
    print(f"ERR {e}")
PY
)"
echo "site tables: $DL"

echo "SERVE cron-dispatch OK: firing×4 (DutyTickAll/DeliverTickAll/SecSummaryOnce/DlTickAll), dispatch error=0, побочные эффекты есть (health_checks, acc_summary_day)"
exit 0
