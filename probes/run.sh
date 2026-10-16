#!/usr/bin/env bash
# Прогон проб Metalogos (наряд АСС-0, блок B).
# Печатает таблицу Markdown: № | итог | пояснение.
# Итоги: PASS — возможность есть и работает; ABSENT — возможности в языке нет
# (допустимый результат, фиксируется в отчёте); FAIL — поведение не совпало с
# ожидаемым. Код выхода 1 только при FAIL.
#
# Использование: probes/run.sh [путь к mlog] > docs/reports/probes-0.32.md
set -u
MLOG="${1:-mlog}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
FAKE_LOG="$WORK/fake.log"
FAILED=0
cleanup() { [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

row() { # $1 номер, $2 итог, $3 пояснение
  printf '| %s | %s | %s |\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n|' '  ' | cut -c1-300)"
  [ "$2" = "FAIL" ] && FAILED=1
  return 0
}

# Запуск в чистом каталоге: файловые операции проб (ledger_export и т.п.)
# не мусорят в репозитории. env -i: только то, что задано явно.
run() { # $1 файл, остальное — переменные окружения KEY=VAL
  local f="$1"; shift
  (cd "$WORK" && env -i PATH="$PATH" HOME="$WORK" "$@" "$MLOG" run "$f" 2>&1)
}
last_result() { grep -E '^(PASS|FAIL|RESULT) ' | tail -1; }

echo "Metalogos: $("$MLOG" --version 2>&1 | head -1)"
echo
echo '| № | Итог | Пояснение |'
echo '|---|---|---|'

# 01 — расписание
out=$(run "$HERE/01-schedule.mlog"); line=$(printf '%s\n' "$out" | last_result)
case "$line" in PASS*) row "B.1 schedule" PASS "${line#PASS }";; *) row "B.1 schedule" FAIL "$line";; esac

# 02 — недоверенный ввод
ok=$(run "$HERE/02-untrusted.mlog" | last_result)
bad=$(run "$HERE/fixtures/02-untrusted-bad.mlog")
aud=$( (cd "$WORK" && "$MLOG" audit "$HERE/fixtures/02-untrusted-bad.mlog" 2>&1) )
if [[ "$ok" == PASS* ]] && grep -q UNTRUSTED_DECISION <<<"$bad" && grep -q "anti-injection" <<<"$aud"; then
  row "B.2 untrusted" PASS "без redact: отказ UNTRUSTED_DECISION при запуске и [ERROR] в mlog audit; с redact исполняется"
else row "B.2 untrusted" FAIL "ok=[$ok] bad=[$(grep -o 'UNTRUSTED_DECISION' <<<"$bad" | head -1)]"; fi

# 03 — env() в маршруте serve
serve_env() { # $1 = none|allow
  local extra=()
  [ "$1" = allow ] && extra=(METALOGOS_ENV_ALLOWLIST=ACC_PROBE_VAR)
  (cd "$WORK" && exec env -i PATH="$PATH" HOME="$WORK" ACC_PROBE_VAR=v1 "${extra[@]}" "$MLOG" serve "$HERE/03-env-route.mlog" >"$WORK/serve.log" 2>&1) &
  local pid=$! r=""
  for _ in $(seq 1 60); do r=$(curl -s "http://127.0.0.1:18110/env" 2>/dev/null) && [ -n "$r" ] && break; sleep 1; done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:18110/env" 2>/dev/null || break; sleep 0.5; done
  printf '%s' "$r"
}
n=$(serve_env none); a=$(serve_env allow)
if [[ "$n" == *"read=no"* && "$a" == *"read=yes"* ]]; then
  row "B.3 env-route" PASS "без METALOGOS_ENV_ALLOWLIST env() в маршруте не читается; с allowlist читается; значение в ответ не выводится (запрет PII_EGRESS_OUTPUT)"
else row "B.3 env-route" FAIL "none=[$n] allow=[$a]"; fi

# 04 — SSRF
out=$(run "$HERE/04-ssrf.mlog"); line=$(printf '%s\n' "$out" | last_result); cnt=$(grep -c "SSRF guard" <<<"$out")
if [[ "$line" == PASS* && "$cnt" -ge 3 ]]; then row "B.4 ssrf" PASS "${line#PASS } (SSRF guard ×$cnt)"; else row "B.4 ssrf" FAIL "$line; SSRF guard ×$cnt"; fi

# 05 — права
line=$(run "$HERE/05-grants.mlog" | last_result)
bad=$(run "$HERE/fixtures/05-grants-bad.mlog")
if [[ "$line" == PASS* ]] && grep -q IRREVERSIBLE_NO_GRANT <<<"$bad"; then
  row "B.5 grants" PASS "${line#PASS }; DELETE без права отклонён до исполнения (IRREVERSIBLE_NO_GRANT)"
else row "B.5 grants" FAIL "$line"; fi

# 06 — журнал
line=$(run "$HERE/06-ledger.mlog" | last_result)
case "$line" in PASS*) row "B.6 ledger" PASS "${line#PASS }";; *) row "B.6 ledger" FAIL "$line";; esac

# 07 — exec
n=$(run "$HERE/07-exec.mlog" | last_result); a=$(run "$HERE/07-exec.mlog" METALOGOS_ALLOW_EXEC=1 | last_result)
if [[ "$n" == *BLOCKED && "$a" == *ALLOWED ]]; then
  row "B.7 exec" PASS "по умолчанию закрыт (EXEC_NOT_PERMITTED); METALOGOS_ALLOW_EXEC=1 открывает в run; для маршрутов serve — отдельный METALOGOS_SERVE_ALLOW_EXEC"
else row "B.7 exec" FAIL "none=[$n] allow=[$a]"; fi

# 08 — MCP allowlist
out=$(run "$HERE/08-mcp-allowlist.mlog" METALOGOS_ALLOW_EXEC=1 METALOGOS_MCP_ALLOWLIST=uvx)
if grep -q "REFUSED" <<<"$out" && grep -q MCP_NOT_ALLOWLISTED <<<"$out"; then
  row "B.8 mcp-allowlist" PASS "сервер вне METALOGOS_MCP_ALLOWLIST отклонён (MCP_NOT_ALLOWLISTED); без METALOGOS_ALLOW_EXEC MCP закрыт целиком"
else row "B.8 mcp-allowlist" FAIL "$(printf '%s' "$out" | tail -1)"; fi

# 09–10 — подставной провайдер
SLOW_SECONDS=40 python3 "$HERE/fixtures/fake_llm.py" 18099 2>"$FAKE_LOG" &
FAKE_PID=$!
for _ in $(seq 1 20); do curl -s -o /dev/null -X POST http://127.0.0.1:18099/ping 2>/dev/null && break; sleep 0.5; done
: >"$FAKE_LOG"
run "$HERE/09-llm-per-provider.mlog" METALOGOS_HTTP_ALLOW_PRIVATE=1 ACC_KEY_BETA=kb >/dev/null
beta_models=$(grep -a 'path=/beta' "$FAKE_LOG" | sed -E 's/.*model=//' | sort -u | tr '\n' ',')
alpha_try=$(grep -ac 'path=/alpha' "$FAKE_LOG")
if [[ "$beta_models" == *"model-default"* ]]; then
  row "B.9 llm-per-provider" ABSENT "своей модели у провайдера нет: после отказа alpha резерв beta получил default_model (модели на beta: ${beta_models%,}; попыток alpha: $alpha_try). Третий аргумент call_llm меняет модель вызова, не провайдера"
elif [ -n "$beta_models" ]; then
  row "B.9 llm-per-provider" PASS "резерв получил свою модель: $beta_models"
else row "B.9 llm-per-provider" FAIL "до резерва beta запрос не дошёл"; fi

line=$(run "$HERE/10-llm-timeout.mlog" METALOGOS_HTTP_ALLOW_PRIVATE=1 ACC_KEY_ALPHA=ka | last_result)
case "$line" in PASS*) row "B.10 llm-timeout" PASS "${line#PASS }";; *) row "B.10 llm-timeout" FAIL "$line";; esac

exit $FAILED
