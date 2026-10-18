#!/usr/bin/env python3
"""Фикстура полигона deadlines (наряд АСС-1.4, A.4): вместо сети.

Выдаёт ответ по номеру вызова (счётчик в data/dl_state, лог вызовов в
data/dl_calls.txt — полигон проверяет по ним, что отказ «чужой домен»
прошёл БЕЗ exec). Сценарии (вызов №):
  1 — срок +90 дней (задача 1: событий нет);
  2 — срок +30 дней (задача 2: один deadline_warn(30));
  3 — срок +30 дней (задача 2: повторный прогон — ноль новых);
  4 — срок +5 дней (задача 3: deadline_warn(7));
  5 — expires=null (задача 4: ручное поле паспорта, source=manual).
"""
import json
import os
import sys
from datetime import date, timedelta

domain = sys.argv[1]
state_f = "data/dl_state"
n = 0
if os.path.exists(state_f):
    with open(state_f, "r", encoding="utf-8") as f:
        n = int(f.read().strip() or "0")
n += 1
with open(state_f, "w", encoding="utf-8") as f:
    f.write(str(n))
with open("data/dl_calls.txt", "a", encoding="utf-8") as f:
    f.write(os.path.basename(sys.argv[0]) + " " + domain + "\n")

exp = None
if n == 1:
    exp = date.today() + timedelta(days=90)
elif n in (2, 3):
    exp = date.today() + timedelta(days=30)
elif n == 4:
    exp = date.today() + timedelta(days=5)

out = {
    "domain": domain,
    "expires": exp.isoformat() if exp else None,
    "source": "rdap",
    "error": None if exp else "fixture: срок не найден (вызов %d)" % n,
}
print(json.dumps(out))
