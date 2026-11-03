#!/usr/bin/env bash
# Полигон Цен (наряд АСС-3.1, A.4): фикстуры-страницы вместо сети
# (запрет наряда: никаких запросов к поставщикам), детерминированный
# разбор, приёмка ТЗ §10.6.
#
# Запуск из корня репо: bash tests/polygon/prices/run.sh [путь к mlog]
# Ожидаемо: POLYGON prices 6/6 (и бонус-гвард stale — Loud при провале)
set -uo pipefail

ML="${1:-mlog}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d /tmp/acc_polygon_prices.XXXXXX)"
ERRLOG="$(mktemp /tmp/acc_polygon_prices.XXXXXX.err)"
trap 'rm -rf "$WORK"' EXIT

# дерево запуска: прод-модули + фикстуры страниц + параметры реестра
mkdir -p "$WORK/registry"
cp -r "$ROOT/modules" "$WORK/modules"
cp -r "$HERE/pages" "$WORK/pages"
cp "$ROOT/registry/prices_params.json" "$WORK/registry/"
cp "$HERE/run.mlog" "$WORK/run.mlog"

cd "$WORK"
"$ML" run run.mlog 2>"$ERRLOG"
status=$?
grep -v REDACT "$ERRLOG" | grep "\[try\]\|error" | head -5 || true
exit $status
