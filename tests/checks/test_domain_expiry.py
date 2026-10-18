"""Юнит-тесты checks/domain_expiry.py (наряд АСС-1.4, A.1) — моки сети.

Запуск из корня репо: python3 -m unittest discover -s tests/checks -v
"""
import importlib.util
import io
import json
import os
import socket
import sys
import unittest
from unittest import mock

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)

SPEC = importlib.util.spec_from_file_location(
    "domain_expiry", os.path.join(ROOT, "checks", "domain_expiry.py"))
de = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(de)

BOOTSTRAP = {"services": [
    [["plus"], ["https://rdap.example.test/rdap"]],
    # .by — RDAP у зоны нет (факт C.3) → путь WHOIS
]}


class FakeHTTP:
    def __init__(self, payloads):
        self._payloads = payloads

    def __call__(self, url, timeout=None):
        url = getattr(url, "full_url", url)
        for prefix, payload in self._payloads:
            if url.startswith(prefix):
                if isinstance(payload, Exception):
                    raise payload
                return io.BytesIO(json.dumps(payload).encode())
        raise AssertionError("неожиданный url: " + url)


def fake_whois(responses):
    """Подмена socket.create_connection: сервер → ответ."""
    class Sock:
        def __init__(self, resp):
            self._resp = resp

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def sendall(self, b):
            pass

        def recv(self, n):
            data = self._resp
            self._resp = b""
            return data

    def _conn(addr, timeout=None):
        host = addr[0]
        return Sock(responses.get(host, b""))
    return _conn


BY_WHOIS = (b"Domain Name: PRAVO.BY\nRegistrar: Reserved\n"
            b"Admin Contact: Hidden Person\nPhone: +375 00 000-00-00\n"
            b"Expiration Date: 2026-10-26\n")
IANA_WHOIS = b"whois: whois.cctld.by\n% IANA WHOIS server\n"


class TestDomainExpiry(unittest.TestCase):
    def test_rdap_path(self):
        rdap = {"events": [{"eventAction": "expiration", "eventDate": "2027-09-15T00:00:00Z"}]}
        with mock.patch.object(de.urllib.request, "urlopen",
                               FakeHTTP([("https://data.iana.org", BOOTSTRAP),
                                         ("https://rdap.example.test/rdap/domain/", rdap)])):
            out = de.domain_expiry("tega.plus")
        self.assertEqual(out["expires"], "2027-09-15")
        self.assertEqual(out["source"], "rdap")
        self.assertIsNone(out["error"])

    def test_rdap_403_falls_back_to_whois(self):
        # факт C.3: RDAP .plus с раннера отвечает 403 → WHOIS
        rdap = de.urllib.error.HTTPError("u", 403, "Forbidden", {}, io.BytesIO())
        with mock.patch.object(de.urllib.request, "urlopen",
                               FakeHTTP([("https://data.iana.org", BOOTSTRAP),
                                         ("https://rdap.example.test/rdap/domain/", rdap)])), \
             mock.patch.object(socket, "create_connection",
                               fake_whois({"whois.iana.org": IANA_WHOIS,
                                           "whois.cctld.by": BY_WHOIS})):
            out = de.domain_expiry("tega.plus")
        self.assertEqual(out["expires"], "2026-10-26")
        self.assertEqual(out["source"], "whois")
        self.assertIsNone(out["error"])

    def test_by_zone_whois_direct(self):
        with mock.patch.object(de.urllib.request, "urlopen",
                               FakeHTTP([("https://data.iana.org", BOOTSTRAP)])), \
             mock.patch.object(socket, "create_connection",
                               fake_whois({"whois.iana.org": IANA_WHOIS,
                                           "whois.cctld.by": BY_WHOIS})):
            out = de.domain_expiry("pravo.by")
        self.assertEqual(out["expires"], "2026-10-26")
        self.assertEqual(out["source"], "whois")
        self.assertIsNone(out["error"])

    def test_no_personal_data_in_output(self):
        # наряд: контакты и владелец из WHOIS не выводятся
        with mock.patch.object(de.urllib.request, "urlopen",
                               FakeHTTP([("https://data.iana.org", BOOTSTRAP)])), \
             mock.patch.object(socket, "create_connection",
                               fake_whois({"whois.iana.org": IANA_WHOIS,
                                           "whois.cctld.by": BY_WHOIS})):
            out = de.domain_expiry("pravo.by")
        blob = json.dumps(out, ensure_ascii=False)
        self.assertNotIn("Hidden Person", blob)
        self.assertNotIn("+375", blob)
        self.assertNotIn("Reserved", blob)
        self.assertNotIn("Admin", blob)

    def test_all_network_fails_contract(self):
        # всё падает → expires=null, error заполнен, JSON валиден
        with mock.patch.object(de.urllib.request, "urlopen",
                               FakeHTTP([("https://data.iana.org", OSError("down"))])):
            out = de.domain_expiry("down.invalid")
        self.assertIsNone(out["expires"])
        self.assertTrue(out["error"])
        self.assertIn("domain", out)

    def test_to_iso_formats(self):
        self.assertEqual(de.to_iso("paid-till: 2027-05-14T00:00:00+03:00"), "2027-05-14")
        self.assertEqual(de.to_iso("Expiration Date: 15-sep-2027."), "2027-09-15")
        self.assertEqual(de.to_iso("Expiration Date: 15.09.2027"), "2027-09-15")
        self.assertIsNone(de.to_iso("никакой даты тут нет"))


if __name__ == "__main__":
    unittest.main()
