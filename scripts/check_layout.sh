#!/usr/bin/env bash
# Гард структуры (наряд АСС-0, A.1): каталоги из ТЗ §4 существуют и описаны README.
set -eu
cd "$(dirname "$0")/.."
missing=0
for d in core registry adapters modules profiles library skills sites tests/polygon probes docs/adr docs/reports data; do
  if [ ! -d "$d" ]; then echo "НЕТ КАТАЛОГА: $d"; missing=1; continue; fi
  case "$d" in probes|docs/adr) continue;; esac
  [ -f "$d/README.md" ] || { echo "НЕТ README: $d/README.md"; missing=1; }
done
for f in README.md AGENTS.md CLAUDE.md app.mlog Dockerfile .env.example docs/adr/0001-decisions-2026-10-16.md .github/ISSUE_TEMPLATE/naryad.md; do
  [ -f "$f" ] || { echo "НЕТ ФАЙЛА: $f"; missing=1; }
done
# .env.example — только имена, без значений (комментарии разрешены)
if grep -vE '^\s*(#|$)' .env.example | grep -qE '=.+'; then echo ".env.example содержит значения"; missing=1; fi
[ "$missing" = 0 ] && echo "layout OK"
exit "$missing"
