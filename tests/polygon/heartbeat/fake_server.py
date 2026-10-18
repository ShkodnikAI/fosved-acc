#!/usr/bin/env python3
"""Фейковые адреса полигона heartbeat (наряд АСС-1.6, A.3).

HTTP-сервер на 127.0.0.1:18991 (только тест):
  /p1, /p2, /health  — «страницы сайта» для цикла Дежурного;
  /ping              — пинг «мёртвой руки»: каждый вызов +1 в файл
                       hb_count (cwd процесса — корень тестового дерева).
"""
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

COUNT = "hb_count"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ping":
            n = 0
            if os.path.exists(COUNT):
                with open(COUNT) as f:
                    n = int(f.read().strip() or "0")
            with open(COUNT, "w") as f:
                f.write(str(n + 1))
            body = b"pong"
        elif self.path == "/health":
            body = b"ok"
        elif self.path in ("/p1", "/p2"):
            body = "Сайт тест".encode()
        else:
            body = b"nope"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *a):
        import sys
        print("REQ:", self.path, file=sys.stderr, flush=True)


HTTPServer(("127.0.0.1", 18991), H).serve_forever()
