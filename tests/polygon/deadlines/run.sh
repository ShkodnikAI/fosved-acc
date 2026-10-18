#!/usr/bin/env bash
# Полигон Дедлайнов (наряд АСС-1.4, A.4): фикстура вместо сети + прогон задач.
# Подмена скриптов — в ОТДЕЛЬНОМ дереве (mktemp), продуктовые файлы не
# трогаются: exec-команда фиксированная ("python3 checks/<скрипт> <домен>",
# относительный путь), поэтому cwd-переключение заменяет scripts/ на
# фикстуры. METALOGOS_ALLOW_EXEC=1 — только здесь (тест, run-режим);
# в проде serve — отдельный METALOGOS_SERVE_ALLOW_EXEC (Dockerfile).
#
# Запуск из корня репо: bash tests/polygon/deadlines/run.sh [путь к mlog]
# Ожидаемо: POLYGON deadlines 5/5
set -uo pipefail

ML="${1:-mlog}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d /tmp/acc_polygon_dl.XXXXXX)"
ERRLOG="$(mktemp /tmp/acc_polygon_dl.XXXXXX.err)"
trap 'rm -rf "$WORK"' EXIT

# дерево запуска: прод-модули + фикстуры + паспорт полигона
mkdir -p "$WORK/checks" "$WORK/data/sites/dlfake"
cp -r "$ROOT/core" "$WORK/core"
cp -r "$ROOT/modules" "$WORK/modules"
cp "$HERE"/fixture_checks/*.py "$WORK/checks/"
cp "$HERE/run.mlog" "$WORK/run.mlog"
cp "$HERE/passport.json" "$WORK/data/sites/dlfake/passport.json"

cd "$WORK"
METALOGOS_ALLOW_EXEC=1 "$ML" run run.mlog 2>"$ERRLOG"
status=$?
grep -v REDACT "$ERRLOG" | grep "\[try\]\|error" | head -5 || true
exit $status
