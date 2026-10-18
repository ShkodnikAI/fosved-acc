#!/usr/bin/env bash
# Полигон «мёртвой руки» (наряд АСС-1.6, A.3): фейк-сервер + 3 прогона
# из отдельных деревьев (см. run.mlog). METALOGOS_HTTP_ALLOW_PRIVATE=1 —
# ТОЛЬКО здесь (тест): ACC_HEARTBEAT_URL указывает на 127.0.0.1.
#
# Запуск из корня репо: bash tests/polygon/heartbeat/run.sh [путь к mlog]
# Ожидаемо: POLYGON heartbeat 3/3
set -uo pipefail

ML="${1:-mlog}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

make_tree() {
  # по умолчанию — ТОЛЬКО ок-сайт (битый паспорт добавляет кейс 2:
  # parse_json в DutyHasModule без try — громкая ошибка, тик умирает)
  local W="$(mktemp -d /tmp/acc_polygon_hb.XXXXXX)"
  mkdir -p "$W/data/sites/hbfake"
  cp -r "$ROOT/core" "$W/core"
  cp -r "$ROOT/modules" "$W/modules"
  cp "$ROOT/tests/polygon/heartbeat/run.mlog" "$W/"
  cp "$ROOT/tests/polygon/heartbeat/fake_server.py" "$W/"
  # паспорт ок-сайта (duty): обе страницы фейка отвечают
  cat > "$W/data/sites/hbfake/passport.json" <<'EOS'
{
  "slug": "hbfake",
  "name": "HB Fake",
  "url": "http://127.0.0.1:18991",
  "timezone": "UTC",
  "checks": {"uptime_every_min": 5, "daily_at": "07:00",
    "pages": [{"path": "/p1", "expect_text": "Сайт тест"},
              {"path": "/p2", "expect_text": "Сайт тест"}]},
  "repo": {"github": "ShkodnikAI/hb-fake", "branch": "main",
    "deploy": "none", "health_url": "http://127.0.0.1:18991/health",
    "key_envs": []},
  "modules": ["duty"],
  "domain": {"registrar": null, "registrar_panel_url": null, "expires": null,
    "expires_source": "auto", "autorenew": null, "dns_provider": null,
    "warn_days": [60, 30, 7], "renewal_owner": "owner"},
  "profile": "showcase", "participation": "pr_with_approval",
  "platform": {"adapter": "render", "cdn": null},
  "models": {"policy": "router", "allow": [], "deny": [], "tokens_per_day": 0},
  "sources": []
}
EOS
  echo "$W"
}

FAKE_LOG="$(mktemp /tmp/acc_hb_fake.XXXXXX.log)"
FAKE_PID=""
trap 'kill "$FAKE_PID" 2>/dev/null || true; rm -rf /tmp/acc_polygon_hb.* "$FAKE_LOG"' EXIT

start_fake() {
  # сервер в cwd дерева: счётчик hb_count — в дереве кейса.
  # cd в текущем шелле (не под-шелл): иначе $! — PID под-оболочки и
  # kill оставляет python-сироту, держащий порт
  cd "$1"
  python3 fake_server.py > "$FAKE_LOG" 2>&1 &
  FAKE_PID=$!
  cd "$ROOT"
  local up=0
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:18991/health" 2>/dev/null && up=1 && break
    sleep 0.25
  done
  if [ "$up" != "1" ]; then
    echo "POLYGON heartbeat FAIL: фейк-сервер не поднялся"; tail -3 "$FAKE_LOG"; exit 1
  fi
}

stop_fake() { kill "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""; sleep 0.3; }

run_case() {
  local W="$1"; shift
  ( cd "$W" && METALOGOS_HTTP_ALLOW_PRIVATE=1 env "$@" "$ML" run run.mlog 2>"$W/run.err" )
}

ok=0
fail=0
mark() { if [ "$1" = "$2" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL: $3 (got [$1], want [$2])"; fi }

# 1) успешный цикл + heartbeat URL → пинг есть
W1="$(make_tree)"
start_fake "$W1"
out1="$(run_case "$W1" "ACC_HEARTBEAT_URL=http://127.0.0.1:18991/ping")"
mark "$out1" "tick=ok hb_count=1" "1: пинг после успешного цикла"

stop_fake
# 2) упавший цикл (битый паспорт) → пинга нет
W2="$(make_tree)"
mkdir -p "$W2/data/sites/hbbad"
echo '{not-json' > "$W2/data/sites/hbbad/passport.json"
start_fake "$W2"
out2="$(run_case "$W2" "ACC_HEARTBEAT_URL=http://127.0.0.1:18991/ping")"
mark "$out2" "tick=err hb_count=0" "2: пинга нет при упавшем цикле"

stop_fake
# 3) пустой ACC_HEARTBEAT_URL → пропуск, пинга нет
W3="$(make_tree)"
start_fake "$W3"
out3="$(run_case "$W3" "ACC_HEARTBEAT_URL=")"
mark "$out3" "tick=ok hb_count=0" "3: пустой env — пропуск"

if [ "$fail" = 0 ]; then
  echo "POLYGON heartbeat 3/3"
else
  echo "POLYGON heartbeat FAIL (OK=$ok FAIL=$fail)"
  exit 1
fi
