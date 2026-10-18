#!/usr/bin/env python3
"""Фейк-сайт полигона Дежурного (наряд АСС-1.3, A.4). Порт 18455, localhost.

Сбои заданы ОКНАМИ хитов (каждый цикл Дежурного проверяет ВСЕ страницы,
поэтому сценарии разведены по номерам хитов; счётчики сбрасываются при
старте сервера). Порядок циклов в run.mlog:
  s1 → s4 → s2 → s3 → s5a → s5b (хиты 1..6 по каждой странице)

  /p1     → всегда 200 «ТЭГА ПЛЮС главная страница»
  /p2     → 500 на хитах 3–4 (сценарий 2: цикл+подтверждение), иначе 200
  /p3     → 200 с текстом на хитах 1–3; с 4-го — 200 без текста (сценарий 3)
  /p4     → 500 на хите 2 (сценарий 4: разовый сбой), иначе 200
  /health → всегда 200 "ok"
"""
import http.server
import socketserver

PORT = 18455
hits = {"p1": 0, "p2": 0, "p3": 0, "p4": 0, "health": 0}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path.lstrip("/").split("?")[0]
        if p not in hits:
            p = "health" if self.path == "/health" else "none"
        body, code = "not found", 404
        if p == "p1":
            hits["p1"] += 1
            body, code = "ТЭГА ПЛЮС главная страница", 200
        elif p == "p2":
            hits["p2"] += 1
            if 3 <= hits["p2"] <= 4:
                body, code = "boom", 500
            else:
                body, code = "ТЭГА ПЛЮС вторая", 200
        elif p == "p3":
            hits["p3"] += 1
            if hits["p3"] >= 4:
                body, code = "no marker here", 200
            else:
                body, code = "ТЭГА ПЛЮС третья", 200
        elif p == "p4":
            hits["p4"] += 1
            if hits["p4"] == 2:
                body, code = "boom", 500
            else:
                body, code = "ТЭГА ПЛЮС четвёртая", 200
        elif p == "health":
            hits["health"] += 1
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
