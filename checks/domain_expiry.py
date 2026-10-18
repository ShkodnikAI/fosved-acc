"""Срок регистрации домена (наряд АСС-1.4, A.1).

Перенос scripts/research/domain_expiry.py (исследование АСС-0, C.3) с
выходом в JSON по контракту наряда.

RDAP по IANA bootstrap (https://data.iana.org/rdap/dns.json); если у зоны
нет RDAP — WHOIS (порт 43) с сервера зоны из whois.iana.org. Факт C.3:
.by читается по WHOIS (whois.cctld.by), у .plus RDAP-сервер с раннера
GitHub отвечал 403 — поэтому при неудаче RDAP скрипт падает на WHOIS
того же домена.

Одна строка JSON: {"domain", "expires": "YYYY-MM-DD"|null,
"source": "rdap|whois", "error": null|"..."}. Код выхода 0 даже при
ошибке. Таймаут 20 с на операцию. Только stdlib (urllib, socket, json,
re). Персональные данные (контакты, владелец) не выводятся: из WHOIS
читаются только строки поля срока, в результат уходит только дата.
"""
import json
import re
import socket
import sys
import urllib.request

TIMEOUT = 20  # секунд на операцию, контракт A.1

ISO = re.compile(r"\b(\d{4}-\d{2}-\d{2})")
# дд-МММ-гггг ("15-sep-2027") и дд.мм.гггг ("15.09.2027") — у части реестров
DDMMM = re.compile(r"\b(\d{1,2})[-\s]([a-z]{3})[-\s](\d{4})\b", re.I)
DOTS = re.compile(r"\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b")
MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
          "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
# только технические поля срока (наряд: без персональных данных)
EXPIRY_FIELDS = re.compile(
    r"^\s*(registry expiry date|registrar registration expiration date|"
    r"expiration date|paid-till|renewal date|free-date)\s*:\s*(.+)$", re.I)


def http_get(url):
    with urllib.request.urlopen(urllib.request.Request(
            url, headers={"Accept": "application/rdap+json, application/json"}),
            timeout=TIMEOUT) as r:
        return json.load(r)


def whois(server, query):
    with socket.create_connection((server, 43), timeout=TIMEOUT) as s:
        s.sendall((query + "\r\n").encode())
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
    return data.decode("utf-8", "replace")


def to_iso(text):
    """Первая дата (ISO / дд-МММ-гггг / дд.мм.гггг) -> 'YYYY-MM-DD' | None."""
    m = ISO.search(text)
    if m:
        return m.group(1)
    m = DDMMM.search(text)
    if m:
        mon = MONTHS.get(m.group(2).lower())
        if mon:
            return "%04d-%02d-%02d" % (int(m.group(3)), mon, int(m.group(1)))
    m = DOTS.search(text)
    if m:
        return "%04d-%02d-%02d" % (int(m.group(3)), int(m.group(2)), int(m.group(1)))
    return None


def rdap_expiry(domain, base):
    d = http_get(base + "/domain/" + domain)
    ev = {e.get("eventAction"): e.get("eventDate") for e in d.get("events", [])}
    return to_iso(str(ev.get("expiration") or ""))


def whois_expiry(domain):
    tld = domain.rsplit(".", 1)[-1].lower()
    iana = whois("whois.iana.org", tld)
    m = re.search(r"^whois:\s*(\S+)", iana, re.M)
    if not m:
        return None, "WHOIS-сервер зоны не найден у whois.iana.org"
    for line in whois(m.group(1), domain).splitlines():
        fm = EXPIRY_FIELDS.match(line)
        if fm:
            iso = to_iso(fm.group(2))
            if iso:
                return iso, None
    return None, "поле срока в ответе WHOIS не найдено"


def domain_expiry(domain):
    out = {"domain": domain, "expires": None, "source": "rdap", "error": None}
    try:
        boot = http_get("https://data.iana.org/rdap/dns.json")
        tld = domain.rsplit(".", 1)[-1].lower()
        servers = [s for tlds, urls in boot["services"]
                   for t in tlds if t == tld for s in urls]
        if servers:
            try:
                out["expires"] = rdap_expiry(domain, servers[0].rstrip("/"))
                out["source"] = "rdap"
                if out["expires"] is None:
                    out["error"] = "RDAP ответил без даты expiration"
            except Exception as e:  # noqa: BLE001
                out["error"] = "rdap %s: %s: %s" % (servers[0], type(e).__name__, e)
        else:
            out["error"] = "зоны нет в IANA bootstrap"
        if out["expires"] is None:
            # фолбэк WHOIS (факт C.3: .by — только WHOIS; .plus RDAP 403)
            try:
                iso, err = whois_expiry(domain)
                out["source"] = "whois"
                if iso:
                    out["expires"], out["error"] = iso, None
                else:
                    tail = err or "WHOIS: дата не найдена"
                    out["error"] = (out["error"] + "; " if out["error"] else "") + tail
            except Exception as e:  # noqa: BLE001
                out["source"] = "whois"
                tail = "whois: %s: %s" % (type(e).__name__, e)
                out["error"] = (out["error"] + "; " if out["error"] else "") + tail
    except Exception as e:  # noqa: BLE001 — контракт: ошибка уходит в JSON, код 0
        out["error"] = "bootstrap: %s: %s" % (type(e).__name__, e)
    return out


def main():
    if len(sys.argv) != 2:
        print(json.dumps({"domain": "", "expires": None, "source": "rdap",
                          "error": "ожидался один аргумент — домен"}))
        return 0
    print(json.dumps(domain_expiry(sys.argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
