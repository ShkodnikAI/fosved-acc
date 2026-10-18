#!/usr/bin/env bash
# Проверка образа (АСС-0) с одним задокументированным допуском:
#  - mlog check — без условий;
#  - mlog audit — [ERROR] запрещён; любой [WARN], КРОМЕ известного
#    «POST routes without CSRF middleware» для /tg, запрещён.
# Допуск: csrf middleware 403-ит Telegram-webhook (server-to-server —
# csrf-токена нет, проба наряда АСС-1.5), аутентификация /tg — секрет-
# заголовок через ct_eq (наряд АСС-1.5 A.1). См. комментарий middleware в
# app.mlog.
set -euo pipefail
cd "$(dirname "$0")/.."
ML="${MLOG_BIN:-mlog}"
"$ML" check app.mlog
"$ML" audit app.mlog > /tmp/acc-audit-docker.log || true
if grep -q "\[ERROR\]" /tmp/acc-audit-docker.log; then
  echo "docker audit: [ERROR] найдены:"
  grep "\[ERROR\]" /tmp/acc-audit-docker.log
  exit 1
fi
if grep "\[WARN\]" /tmp/acc-audit-docker.log | grep -qv "POST routes without CSRF middleware"; then
  echo "docker audit: неизвестный [WARN]:"
  grep "\[WARN\]" /tmp/acc-audit-docker.log
  exit 1
fi
echo "docker audit OK (допуск: csrf для Telegram-webhook, см. app.mlog)"
