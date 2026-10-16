"""Подставной OpenAI-совместимый провайдер для проб 09/10.

Пишет в stderr одну строку на запрос: путь, есть ли Bearer-ключ, пришедшее поле model.
Путь /slow/... отвечает через SLOW_SECONDS секунд (проба таймаута).
Ключи не печатаются: только признак наличия.
"""
import http.server, json, os, sys, time

SLOW = float(os.environ.get("SLOW_SECONDS", "40"))

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        auth = self.headers.get("Authorization", "")
        has_key = auth.startswith("Bearer ") and len(auth) > 7
        sys.stderr.write(f"REQ path={self.path} key={'yes' if has_key else 'no'} model={body.get('model')}\n")
        sys.stderr.flush()
        if self.path.startswith("/slow"):
            try:
                time.sleep(SLOW)
            except Exception:
                return
        if not has_key:
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error":{"message":"Missing API key"}}'); return
        out = {"choices": [{"message": {"role": "assistant", "content": "OK " + self.path + " " + str(body.get("model"))}, "finish_reason": "stop"}],
               "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(out).encode())
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18099
    http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
