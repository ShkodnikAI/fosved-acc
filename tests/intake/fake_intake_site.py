#!/usr/bin/env python3
"""Фейк-сайты разведки (наряд АСС-2.5, A.3). Два сервера:
  18488 — полный: / (title, ссылки навигации, github-ссылка), /be/ /en/ /ru/
          (lang-атрибут), /health;
  18489 — без /health и без языковых страниц (для теста 2: null).
ALLOW_PRIVATE — только в тесте (run.sh)."""
import http.server
import socketserver
import threading

FULL = 18488
MIN = 18489

PAGE_FULL = """<html lang="ru"><head><title>ТЭГА ПЛЮС — главная</title></head>
<body><nav>
<a href="/services">Юридические услуги</a>
<a href="/kontakty">Контакты</a>
<a href="/about">О компании</a>
<a href="https://github.com/ShkodnikAI/tega">GitHub</a>
<a href="https://t.me/tega">Telegram</a>
</nav>
<p>См. https://github.com/ShkodnikAI/tegaPlatform</p>
</body></html>"""

PAGE_FULL_BE = """<html lang="be"><head><title>ТЭГА ПЛЮС — беларуская</title></head><body>Юрыдычныя паслугі</body></html>"""
PAGE_FULL_EN = """<html lang="en"><head><title>TEGA PLUS — English</title></head><body>Legal services</body></html>"""
PAGE_FULL_RU = """<html lang="ru"><head><title>ТЭГА ПЛЮС — русский</title></head><body>Юридические услуги</body></html>"""

PAGE_MIN = """<html lang="ru"><head><title>Минимальный сайт</title></head><body><a href="/x">X</a></body></html>"""


class Full(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path
        if p == "/":
            body, code = PAGE_FULL, 200
        elif p == "/be/":
            body, code = PAGE_FULL_BE, 200
        elif p == "/en/":
            body, code = PAGE_FULL_EN, 200
        elif p == "/ru/":
            body, code = PAGE_FULL_RU, 200
        elif p == "/health":
            body, code = "ok", 200
        else:
            body, code = "not found", 404
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class Min(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body, code = PAGE_MIN, 200
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def serve(port, handler):
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    t = threading.Thread(target=serve, args=(MIN, Min), daemon=True)
    t.start()
    serve(FULL, Full)
