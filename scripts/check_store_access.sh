#!/usr/bin/env bash
# Гард A.4.3 наряда АСС-1.2: прямые имена схем сайтов разрешены только
# в core/store.mlog. Все запросы к данным сайта должны идти через имя
# схемы, возвращённое SiteDb (см. core/store.mlog).
set -euo pipefail

hits="$(grep -rnE "site_[a-z0-9_]+\." --include='*.mlog' . | grep -v '^./core/store.mlog' || true)"
if [ -n "$hits" ]; then
  echo "гард: прямые имена схем site_* вне core/store.mlog:"
  echo "$hits"
  exit 1
fi
echo "store access OK"
