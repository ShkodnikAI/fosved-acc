"""Срок TLS-сертификата домена (наряд АСС-1.4, A.1).

Один аргумент — домен. На выходе одна строка JSON:
  {"domain": "...", "expires": "YYYY-MM-DD"|null, "source": "tls", "error": null|"..."}
Код выхода 0 даже при ошибке — ошибка уходит в поле error (контракт A.1).
Таймаут 20 с. Только стандартная библиотека (ssl, socket, json).
Персональных данных в сертификате нет; скрипт ничего, кроме контракта,
не выводит.

Нюанс: сертификат читается через ssl.create_default_context() — цепочка и
срок проверяются рукопожатием. Просроченный/невалидный сертификат даёт
ошибку рукопожатия (expires=null, error=...) — это корректный сигнал
«срок под вопросом»: дальше срабатывает ручное поле паспорта
(АСС-1.4, A.2). Прочитать notAfter невалидного сертификата без сторонних
библиотек (stdlib не парсит DER) нельзя — ограничение задокументировано.
"""
import json
import socket
import ssl
import sys
from datetime import datetime, timezone

TIMEOUT = 20  # секунд, контракт A.1


def parse_not_after(raw):
    """notAfter ('Sep 15 12:00:00 2027 GMT') -> 'YYYY-MM-DD' | None."""
    if not raw:
        return None
    try:
        secs = ssl.cert_time_to_seconds(raw)
        return datetime.fromtimestamp(secs, timezone.utc).date().isoformat()
    except (ValueError, TypeError):
        return None


def cert_expiry(domain):
    out = {"domain": domain, "expires": None, "source": "tls", "error": None}
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((domain, 443), timeout=TIMEOUT) as sock:
            with ctx.wrap_socket(sock, server_hostname=domain) as tls:
                not_after = tls.getpeercert().get("notAfter")
        out["expires"] = parse_not_after(not_after)
        if out["expires"] is None:
            out["error"] = "не удалось разобрать notAfter: %r" % (not_after,)
    except Exception as e:  # noqa: BLE001 — контракт: ошибка уходит в JSON, код 0
        out["error"] = "%s: %s" % (type(e).__name__, e)
    return out


def main():
    if len(sys.argv) != 2:
        print(json.dumps({"domain": "", "expires": None, "source": "tls",
                          "error": "ожидался один аргумент — домен"}))
        return 0
    print(json.dumps(cert_expiry(sys.argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
