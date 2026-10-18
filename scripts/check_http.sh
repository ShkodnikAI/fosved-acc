#!/usr/bin/env bash
# Гард исходящих запросов (наряд АСС-2.1, A.2): http_get/http_post в
# core/ и modules/ — только внутри core/http.mlog (SafeGet/SafePost).
# Комментарии не пропускаем: скобку после имени функции в комментариях
# не оставлять.
set -eu
cd "$(dirname "$0")/.."
if grep -rnE "http_(get|post)\(" --include=*.mlog core modules | grep -v "^core/http.mlog"; then
  echo "ГАРД: исходящие запросы вне core/http.mlog (перевести на SafeGet/SafePost)" >&2
  exit 1
fi
echo "http guard OK"
