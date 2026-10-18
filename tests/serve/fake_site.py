#!/usr/bin/env python3
"""Фейк-сайт serve-теста Дежурного (наряд АСС-1.7, A.2). Порт 18456, localhost.

Проще полигонального (сценарий 2 там разведён окнами хитов): здесь один
сценарий — /p2 отвечает 500 всегда. Первый цикл Дежурного даёт сбой,
подтверждение (sleep 60 + повтор) — второй 500 подряд → инцидент down.

  /p1     → всегда 200 «ТЭГА ПЛЮС главная страница»
  /p2     → всегда 500 "boom" (сценарий 2: цикл + подтверждение)
  /health → всегда 200 "ok"
"""
import http.server
import socketserver

PORT = 18456


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path.lstrip("/").split("?")[0]
        if p not in ("p1", "p2", "health"):
            p = "health" if self.path == "/health" else "none"
        body, code = "not found", 404
        if p == "p1":
            body, code = "ТЭГА ПЛЮС главная страница", 200
        elif p == "p2":
            body, code = "boom", 500
        elif p == "health":
            body, code = "ok", 200
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
