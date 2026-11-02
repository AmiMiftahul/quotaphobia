"""A stand-in for Supabase, for automated tests only. It enforces the same request
shape the real service needs: an apikey on everything, a user token to insert."""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

KEY = "test-publishable-key"
rows = []
users = 0
products = [
    {"id": "skin_engineer", "name": "Engineer crew member", "price_idr": 15000},
    {"id": "skin_medic", "name": "Medic crew member", "price_idr": 15000},
    {"id": "skin_pilot", "name": "Pilot crew member", "price_idr": 25000},
]
orders = {}
owned = set()
# A real, valid 1x1 PNG, standing in for Midtrans's QR image.
QR_PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")


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

    def signed_in(self):
        return self.headers.get("Authorization", "").startswith("Bearer token")

    def do_POST(self):
        global users
        if self.path.startswith("/mock/payment/"):
            # Simulates Midtrans telling the server what happened to an order.
            _, _, _, status, order_id = self.path.split("/")
            orders[order_id]["status"] = status
            if status == "paid":
                owned.add(orders[order_id]["product_id"])
            return self.reply(200, {})
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
        if self.path == "/functions/v1/create-qris-order":
            if not self.signed_in():
                return self.reply(401, {"error": "Please sign in again."})
            if data.get("product_id") in owned:
                return self.reply(409, {"error": "You already own this."})
            product = next((p for p in products if p["id"] == data.get("product_id")), None)
            if not product:
                return self.reply(404, {"error": "That item isn't for sale."})
            order_id = f"ss-{len(orders) + 1}"
            orders[order_id] = {"status": "pending", "product_id": product["id"]}
            print("MOCK_ORDER", order_id, flush=True)
            port = self.server.server_port
            return self.reply(200, {"order_id": order_id, "amount_idr": product["price_idr"],
                                    "qr_url": f"http://127.0.0.1:{port}/mock/qr.png", "expires_minutes": 15})
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
        if self.path == "/mock/qr.png":
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(QR_PNG)))
            self.end_headers()
            self.wfile.write(QR_PNG)
            return
        if self.headers.get("apikey") != KEY:
            return self.reply(401, {"message": "bad apikey"})
        if self.path.startswith("/rest/v1/products?"):
            return self.reply(200, products)
        if self.path.startswith("/rest/v1/entitlements?"):
            if not self.signed_in():
                return self.reply(401, {"message": "not signed in"})
            return self.reply(200, [{"product_id": p} for p in sorted(owned)])
        if self.path.startswith("/rest/v1/orders?"):
            if not self.signed_in():
                return self.reply(401, {"message": "not signed in"})
            order_id = self.path.split("order_id=eq.")[1]
            return self.reply(200, [{"status": orders[order_id]["status"]}] if order_id in orders else [])
        if self.path.startswith("/rest/v1/runs?"):
            return self.reply(200, sorted(rows, key=lambda r: -r["total_scrap"]))
        self.reply(404, {"message": self.path})


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # Skips HTTPServer's reverse DNS lookup, which can hang for minutes on macOS.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
