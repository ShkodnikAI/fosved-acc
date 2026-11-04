#!/usr/bin/env bash
# Гард прямого SQL к файлам сайтов (АСС-1.2 A.4.3 + АСС-1.12 #44 C.2).
# Правило 1 (A.4.3): прямые имена старых схем site_* разрешены только
# в core/store.mlog (наследие миграции — пока файлы старой схемы не
# вычищены из истории, правило остаётся).
# Правило 2 (#44 C.2): ATTACH/DETACH баз данных разрешены только в
# core/store.mlog (шов SiteDb) и в probes/ (пробы — тестовая среда).
# Все запросы к данным сайта — литеральной схемой site после вызова
# SiteDb(slug) (см. core/store.mlog).
set -euo pipefail

hits="$(grep -rnE "site_[a-z0-9_]+\." --include='*.mlog' . | grep -v '^./core/store.mlog' || true)"
if [ -n "$hits" ]; then
  echo "гард: прямые имена схем site_* вне core/store.mlog:"
  echo "$hits"
  exit 1
fi

att="$(grep -rnE "\b(ATTACH|DETACH)\b" --include='*.mlog' . | grep -v '^./core/store.mlog' | grep -v '^./probes/' | grep -vE ':[0-9]+:[[:space:]]*//' || true)"
if [ -n "$att" ]; then
  echo "гард: ATTACH/DETACH вне core/store.mlog и probes/ (шов — только SiteDb, #44 C.2):"
  echo "$att"
  exit 1
fi
echo "store access OK"
