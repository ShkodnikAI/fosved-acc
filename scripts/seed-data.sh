#!/bin/sh
# АСС-1.11 (наряд #39, A.2): раскладка конфигурации из образа (/app/seed)
# в каталог данных (/app/data) на каждом старте контейнера, перед
# `exec mlog serve app.mlog` (Dockerfile, CMD).
#
# Постоянный диск Render смонтирован в /app/data и закрывает всё, что
# образ положил в этот каталог, поэтому конфигурация — паспорта сайтов,
# реестры, статика Mini App — кладётся на диск скриптом при каждом
# старте. Источник правды — репозиторий: изменения паспортов/реестров/
# статики идут через PR и попадают на диск с ПЕРЕЗАПИСЬЮ.
#
# Скрипт ничего не удаляет и не трогает состояние (базы сайтов, журнал,
# memory.db); sites/journal/ и README.md не копируются (sites/journal/
# — рабочее состояние, README.md — документация репозитория).
#
# ACC_SEED_DIR / ACC_DATA_DIR — только для локальных прогонов скрипта
# вне контейнера (тесты); в образе не задаются и defaults совпадают с
# путями контейнера.

set -eu

SEED="${ACC_SEED_DIR:-/app/seed}"
DATA="${ACC_DATA_DIR:-/app/data}"

mkdir -p "$DATA/sites" "$DATA/registry" "$DATA/miniapp-static"

# Паспорта сайтов: для каждого <slug>/passport.json из seed — каталог в
# data/sites/<slug> и копирование с перезаписью. Слуги без паспорта
# (например, пустой journal/) и README.md не копируются.
sites=0
for passport in "$SEED"/sites/*/passport.json; do
  [ -f "$passport" ] || continue
  slug=$(basename "$(dirname "$passport")")
  mkdir -p "$DATA/sites/$slug"
  for f in "$SEED/sites/$slug"/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DATA/sites/$slug/$(basename "$f")"
  done
  sites=$((sites + 1))
done

# Реестры: *.json из seed/registry в data/registry с перезаписью.
registry=0
for f in "$SEED"/registry/*.json; do
  [ -f "$f" ] || continue
  cp -f "$f" "$DATA/registry/$(basename "$f")"
  registry=$((registry + 1))
done

# Статика Mini App: всё содержимое seed/miniapp-static с перезаписью.
static=0
for f in "$SEED"/miniapp-static/*; do
  [ -f "$f" ] || continue
  cp -f "$f" "$DATA/miniapp-static/$(basename "$f")"
  static=$((static + 1))
done

echo "seed: sites=$sites registry=$registry static=$static"
