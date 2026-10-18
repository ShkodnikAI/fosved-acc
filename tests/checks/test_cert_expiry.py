"""Юнит-тесты checks/cert_expiry.py (наряд АСС-1.4, A.1) — моки сети.

Запуск из корня репо: python3 -m unittest discover -s tests/checks -v
"""
import importlib.util
import json
import os
import socket
import ssl
import subprocess
import sys
import unittest
from unittest import mock

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)

SPEC = importlib.util.spec_from_file_location(
    "cert_expiry", os.path.join(ROOT, "checks", "cert_expiry.py"))
ce = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ce)


class FakeSock:
    """Минимальный мок TLS-соединения."""

    def __init__(self, cert):
        self._cert = cert

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def getpeercert(self):
        return self._cert


def fake_connection(cert):
    def _conn(addr, timeout=None):
        return FakeSock(cert)
    return _conn


class TestCertExpiry(unittest.TestCase):
    def test_expires_parsed(self):
        cert = {"notAfter": "Sep 15 12:00:00 2027 GMT"}
        with mock.patch.object(ssl, "create_default_context", lambda: mock.Mock(wrap_socket=lambda s, server_hostname: FakeSock(cert))), \
             mock.patch.object(socket, "create_connection", fake_connection(cert)):
            out = ce.cert_expiry("example.com")
        self.assertEqual(out["domain"], "example.com")
        self.assertEqual(out["expires"], "2027-09-15")
        self.assertEqual(out["source"], "tls")
        self.assertIsNone(out["error"])

    def test_network_error_gives_json_with_error(self):
        def boom(addr, timeout=None):
            raise OSError("unreachable")
        with mock.patch.object(socket, "create_connection", boom):
            out = ce.cert_expiry("down.invalid")
        self.assertIsNone(out["expires"])
        self.assertIn("OSError", out["error"])

    def test_parse_not_after(self):
        self.assertEqual(ce.parse_not_after("Sep 15 12:00:00 2027 GMT"), "2027-09-15")
        self.assertIsNone(ce.parse_not_after("garbage"))
        self.assertIsNone(ce.parse_not_after(None))

    def test_cli_exit_zero_even_on_error(self):
        # контракт A.1: код выхода 0 даже при ошибке; DNS несуществующего
        # имени падает без сети — ответ всё равно валидный JSON
        r = subprocess.run(
            [sys.executable, os.path.join(ROOT, "checks", "cert_expiry.py"),
             "nonexistent-host-for-test.invalid"],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0)
        d = json.loads(r.stdout)
        self.assertEqual(d["domain"], "nonexistent-host-for-test.invalid")
        self.assertIsNone(d["expires"])
        self.assertTrue(d["error"])


if __name__ == "__main__":
    unittest.main()
