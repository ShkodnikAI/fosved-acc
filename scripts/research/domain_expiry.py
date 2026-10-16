"""C.3 (наряд АСС-0): можно ли автоматически узнать срок регистрации домена.

RDAP по IANA bootstrap (https://data.iana.org/rdap/dns.json); если у зоны нет
RDAP — WHOIS (порт 43) с сервера из whois.iana.org. Печатает только:
зону, источник, регистратора, даты регистрации/окончания, статусы.
Персональные данные (контакты, владелец) не выводятся и не сохраняются.
"""
import json, re, socket, sys, urllib.request

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/rdap+json, application/json"}), timeout=20) as r:
        return json.load(r)

def whois(server, query):
    with socket.create_connection((server, 43), timeout=20) as s:
        s.sendall((query + "\r\n").encode())
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
    return data.decode("utf-8", "replace")

SAFE_WHOIS = re.compile(r"^\s*(registrar|registrar name|created|creation date|paid-till|expiration date|registry expiry date|registrar registration expiration date|updated date|domain status|status|free-date|state)\s*:\s*(.+)$", re.I)

def main(domains):
    boot = get("https://data.iana.org/rdap/dns.json")
    for domain in domains:
        tld = domain.rsplit(".", 1)[-1].lower()
        servers = [s for tlds, urls in boot["services"] for t in tlds if t == tld for s in urls]
        print(f"## {domain} (зона .{tld})")
        if servers:
            base = servers[0].rstrip("/")
            try:
                d = get(f"{base}/domain/{domain}")
                ev = {e.get("eventAction"): e.get("eventDate") for e in d.get("events", [])}
                reg = next((e for e in d.get("entities", []) if "registrar" in e.get("roles", [])), {})
                name = next((v[3] for v in reg.get("vcardArray", [None, []])[1] if v[0] == "fn"), "?") if reg else "?"
                print(f"- источник: RDAP {base}")
                print(f"- регистратор: {name}")
                print(f"- регистрация: {ev.get('registration')}; окончание: {ev.get('expiration')}")
                print(f"- статусы: {', '.join(d.get('status', []))}")
            except Exception as e:  # noqa: BLE001
                print(f"- RDAP {base}: ошибка {type(e).__name__}: {e}")
            continue
        print("- RDAP: зоны нет в IANA bootstrap")
        try:
            iana = whois("whois.iana.org", tld)
            m = re.search(r"^whois:\s*(\S+)", iana, re.M)
            server = m.group(1) if m else None
            print(f"- WHOIS-сервер зоны (whois.iana.org): {server}")
            if server:
                for line in whois(server, domain).splitlines():
                    mm = SAFE_WHOIS.match(line)
                    if mm:
                        print(f"- {mm.group(1).strip()}: {mm.group(2).strip()}")
        except Exception as e:  # noqa: BLE001
            print(f"- WHOIS: ошибка {type(e).__name__}: {e}")

if __name__ == "__main__":
    main(sys.argv[1:] or ["tega.plus", "pravo.by"])
