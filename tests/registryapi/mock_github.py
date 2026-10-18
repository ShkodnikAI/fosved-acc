#!/usr/bin/env python3
"""Мок GitHub API (наряд АСС-2.4, A.3, тест 3): лог вызовов + заглушки
Git Data API. Лог — JSONL в файл из переменной окружения MOCK_LOG:
{"method","path","auth","body"} — body декодируется тестом. Значение
токена НЕ пишется (только факт наличия заголовка Authorization)."""
import http.server
import json
import os
import socketserver

PORT = 18477
LOG = os.environ.get("MOCK_LOG", "/tmp/acc_mock_gh.jsonl")


class Handler(http.server.BaseHTTPRequestHandler):
    def _log(self, body: bytes):
        auth = self.headers.get("Authorization", "")
        rec = {
            "method": self.command,
            "path": self.path,
            "auth": "yes" if auth.startswith("Bearer ") else "no",
            "body": body.decode("utf-8", "replace"),
        }
        with open(LOG, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def _reply(self, code: int, obj: dict):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True})
            return
        self._log(b"")
        if "/git/ref/heads/main" in self.path:
            self._reply(200, {"ref": "refs/heads/main", "object": {"sha": "basesha000", "type": "commit"}})
        elif "/git/commits/" in self.path:
            self._reply(200, {"sha": "basesha000", "tree": {"sha": "basetree000"}})
        else:
            self._reply(404, {"message": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        self._log(body)
        if "/git/blobs" in self.path:
            self._reply(201, {"sha": "blobsha111"})
        elif "/git/trees" in self.path:
            self._reply(201, {"sha": "newtree222"})
        elif "/git/commits" in self.path:
            self._reply(201, {"sha": "commitsha333"})
        elif "/git/refs" in self.path:
            self._reply(201, {"ref": "refs/heads/acc-ui-x"})
        elif "/pulls" in self.path:
            self._reply(201, {"html_url": "https://github.com/ShkodnikAI/fosved-acc/pull/42"})
        else:
            self._reply(404, {"message": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
