#!/usr/bin/env python3
"""mock-server.py - minimal planet-download server used to test the client scripts.

Routes (the same contract the real zerotier-planet planet server exposes):
  GET /healthz  -> 200 {"status":"ok"}
  GET /planet   -> application/octet-stream binary planet file
                   token accepted as ?token=... or "Authorization: Bearer ..."
                   when --token is empty no check is performed
  GET /         -> small HTML download page

The planet served here is a format-conformant stub: its first byte is 0x01
(World::TYPE_PLANET) followed by id/ts/key-set/signature/root-count per
node/World.hpp::serialize. It is NOT a usable planet (no valid signature),
it only exercises the download / validate / replace path of the installers.
"""
import argparse
import hashlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# Synthetic 64-bit world id. Installers only inspect byte 0 (0x01 = TYPE_PLANET)
# and the length, so any u64 works here.
WORLD_ID = 0x1496000000000001


def build_planet_stub(world_id=WORLD_ID):
    b = bytearray()
    b.append(0x01)                              # World::TYPE_PLANET
    b += world_id.to_bytes(8, "big")            # world id
    b += int(time.time()).to_bytes(8, "big")    # timestamp
    b += b"\x00" * 128                          # updatesMustBeSignedBy (64+64)
    b += b"\x00" * 96                           # signature
    b.append(1)                                 # root count
    b += bytes([0xAA] * 5)                      # root identity address
    b.append(0x07)                              # identity type (ed25519)
    b += b"\x00" * 64                           # identity public key
    b.append(1)                                 # stable endpoint count
    b += bytes([0x00, 0x27])                    # port 9993
    b += bytes([127, 0, 0, 1])                  # 127.0.0.1
    return bytes(b)


PLANET = build_planet_stub()


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-planet/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] %s - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()

    def _auth_ok(self, query):
        if not self.server.token:
            return True
        if query.get("token", [""])[0] == self.server.token:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer ") and header[7:].strip() == self.server.token:
            return True
        return False

    def _send(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path

        if path == "/healthz":
            self._send(200, b'{"status":"ok"}\n', "application/json")
            return

        if path == "/text/planet":
            # 200 但内容不是 planet: 用于验证客户端的魔数校验
            self._send(200, b"x" * 512, "text/plain; charset=utf-8")
            return

        if path == "/planet":
            if not self._auth_ok(query):
                self._send(401, b"invalid or missing token\n", "text/plain; charset=utf-8")
                return
            self._send(
                200,
                PLANET,
                "application/octet-stream",
                {
                    "Content-Disposition": 'attachment; filename="planet"',
                    "X-Planet-Sha256": hashlib.sha256(PLANET).hexdigest(),
                },
            )
            return

        if path in ("/", "/index.html"):
            tok = self.server.token
            link = "/planet"
            note = ""
            if tok:
                link = "/planet?token=" + tok
                note = "<p>token: <code>%s</code></p>" % tok
            html = (
                "<!doctype html><meta charset=utf-8><title>planet download</title>"
                "<h1>ZeroTier planet download</h1>"
                "<p><a href=\"%s\">download planet</a></p>%s"
                "<p>安装: <code>install-planet.sh --server-url http://HOST:PORT --token TOKEN</code></p>"
                % (link, note)
            ).encode("utf-8")
            self._send(200, html, "text/html; charset=utf-8")
            return

        self._send(404, b"not found\n", "text/plain; charset=utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18089)
    ap.add_argument("--token", default="", help="empty means no token check")
    args = ap.parse_args()

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.token = args.token
    print(
        "mock planet server on http://%s:%d  planet=%d bytes sha256=%s token=%s"
        % (args.host, args.port, len(PLANET), hashlib.sha256(PLANET).hexdigest(),
           args.token if args.token else "(no check)"),
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
