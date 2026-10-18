#!/usr/bin/env bash
# Шаг CI (наряд АСС-2.4, A.1): файлы реестров в репозитории проходят
# Validate* (формат ADR-0002, секрет-скан правила 8).
set -uo pipefail
cd "$(dirname "$0")/../.."
ML="${1:-mlog}"
OUT="$("$ML" run tests/registry/validate.mlog 2>/dev/null)"
echo "$OUT"
echo "$OUT" | grep -q "REGISTRY VALIDATION OK" || { echo "registry validation FAIL" >&2; exit 1; }
