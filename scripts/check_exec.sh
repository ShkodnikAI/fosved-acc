#!/usr/bin/env bash
# Гард exec (наряд АСС-1.4, A.2): exec разрешён только в одном файле —
# modules/deadlines/run.mlog. В наряде гард написан для литерала "exec(";
# фактическое имя встроенной функции 0.32.0 — exec_argv (probes/07-exec.mlog),
# поэтому шаблон — exec(_argv)?\( . probes/ исключены: там exec — предмет
# самих проб B.7/B.8 (тестовые фикстуры, не прод).
set -euo pipefail
cd "$(dirname "$0")/.."

hits="$(grep -rlnE 'exec(_argv)?\(' --include='*.mlog' --exclude-dir=probes . | grep -v '^./modules/deadlines/run.mlog$' || true)"
if [ -n "$hits" ]; then
  echo "гард exec: exec вне modules/deadlines/run.mlog:"
  echo "$hits"
  exit 1
fi
echo "exec guard OK"
