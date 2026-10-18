#!/usr/bin/env bash
# Тесты allowlist (наряд АСС-2.1, A.3): 6 тестов + мутация (в отчёте PR).
# Без сети: HttpAllowed — чистая проверка; SafeGet в тесте 3 отказывает
# ДО запроса. Без METALOGOS_HTTP_ALLOW_PRIVATE — гард полный (тесты 2–4
# проверяют отклонение; флаг обязан отсутствовать).
#
# Подготовка data/ (зеркало, как в образе — Dockerfile COPY):
#   data/sites/tega/passport.json  ← sites/tega/passport.json
#   data/sites/journal/            ← каталог схемы-журнала отказов
#   data/registry/sources.json     ← registry/sources.json + запись
#                                    disabled.example (тест 5)
# Запуск из корня репо: bash tests/allowlist/run.sh [путь к mlog]
# Ожидаемо: POLYGON allowlist 6/6
set -uo pipefail

ML="${1:-mlog}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

cd "$ROOT"
# чистое окружение теста (тестовая гигиена, как в полигонах)
for f in data/sites/tega/passport.json data/registry/sources.json; do
  if [ -e "$f" ]; then
    echo "POLYGON allowlist FAIL: $f уже существует — нужен чистый data/ (в CI чекаут свежий)"; exit 1
  fi
done
mkdir -p data/sites/tega data/sites/journal data/registry
cp sites/tega/passport.json data/sites/tega/passport.json
python3 - <<'PY'
import json
reg = json.load(open("registry/sources.json"))
reg.append({"id": "x0", "kind": "registry", "domain": "disabled.example",
            "read_method": "http", "frequency": "weekly",
            "terms_checked": True, "status": "disabled"})
json.dump(reg, open("data/registry/sources.json", "w"), ensure_ascii=False, indent=2)
PY

trap 'rm -rf data/sites/tega data/sites/journal data/registry data/acc.db data/acc.db-wal data/acc.db-shm data/memory.db data/checkpoints.db tests/allowlist/probe_out.txt data/probe_out.txt 2>/dev/null || true' EXIT

# mlog run завершается 0 и при FAIL-вердикте — вердикт проверяем grep'ом
OUT="$("$ML" run tests/allowlist/run.mlog)"
echo "$OUT"
if echo "$OUT" | grep -q "POLYGON allowlist 6/6"; then
  exit 0
fi
echo "POLYGON allowlist FAIL: вердикт не 6/6" >&2
exit 1
