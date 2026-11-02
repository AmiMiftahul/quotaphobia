"""A stand-in for Supabase, for automated tests only. It enforces the same request
shape the real service needs: an apikey on everything, a user token to insert."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

KEY = "test-publishable-key"
rows = []
users = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_POST(self):
        global users
        if self.headers.get("apikey") != KEY:
            return self.reply(401, {"message": "bad apikey"})
        data = self.read_json()
        if self.path == "/auth/v1/signup":
            users += 1
            return self.reply(200, {"access_token": f"token{users}", "refresh_token": f"refresh{users}", "expires_in": 3600})
        if self.path == "/auth/v1/token?grant_type=refresh_token":
            if not data.get("refresh_token", "").startswith("refresh"):
                return self.reply(400, {"message": "bad refresh token"})
            print("MOCK_REFRESH", flush=True)
            return self.reply(200, {"access_token": "token-refreshed", "refresh_token": data["refresh_token"], "expires_in": 3600})
        if self.path == "/rest/v1/runs":
            if not self.headers.get("Authorization", "").startswith("Bearer token"):
                return self.reply(401, {"message": "not signed in"})
            if set(data) != {"display_name", "rounds_cleared", "total_scrap", "crew_size"}:
                return self.reply(400, {"message": "unexpected columns"})
            rows.append(data)
            print("MOCK_INSERT", json.dumps(data), flush=True)
            return self.reply(201)
        self.reply(404, {"message": self.path})

    def do_GET(self):
        if self.headers.get("apikey") != KEY:
            return self.reply(401, {"message": "bad apikey"})
        if self.path.startswith("/rest/v1/runs?"):
            return self.reply(200, sorted(rows, key=lambda r: -r["total_scrap"]))
        self.reply(404, {"message": self.path})


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # Skips HTTPServer's reverse DNS lookup, which can hang for minutes on macOS.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
