#!/usr/bin/env python3
"""Read-only download service for a self-hosted ZeroTier planet.

Serves, out of /var/lib/zerotier-one:
  GET /healthz        liveness, always unauthenticated
  GET /planet         the planet (world) file, X-File-SHA256 carries its digest
  GET /moons          JSON list of moon file names
  GET /moon/<name>    one moon file
  GET /               tiny HTML index page

Auth: when DOWNLOAD_TOKEN is non-empty, every endpoint except /healthz requires
it, either as ?token=... or as "Authorization: Bearer ...". Empty token means no
authentication at all. Standard library only, no outbound network access.
"""

import hashlib
import hmac
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

ZT_HOME = os.environ.get("ZT_HOME", "/var/lib/zerotier-one")
PLANET_PATH = os.path.join(ZT_HOME, "planet")
MOONS_DIR = os.path.join(ZT_HOME, "moons.d")
TOKEN = os.environ.get("DOWNLOAD_TOKEN", "")
PORT = int(os.environ.get("FILES_PORT", "3000"))

MOON_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.moon$")

INDEX_TEMPLATE = """<!doctype html>
<html><head><meta charset="utf-8"><title>ZeroTier planet</title>
<style>body{font-family:system-ui,sans-serif;margin:2rem;max-width:48rem}
code{background:#f2f2f2;padding:.1rem .3rem;border-radius:3px}</style></head>
<body>
<h1>ZeroTier planet node</h1>
<ul>
<li><a href="/planet@@SUFFIX@@">planet</a> (world file, sha256 <code>@@DIGEST@@</code>)</li>
<li><a href="/moons@@SUFFIX@@">moons</a> (JSON list)</li>
</ul>
<h2>Moons</h2>
<ul>@@ROWS@@</ul>
<h2>Client setup</h2>
<p>Drop <code>planet</code> into <code>/var/lib/zerotier-one/planet</code> on the client
(<code>&#37;LOCALAPPDATA&#37;\\ZeroTier\\One\\planet</code> on Windows) and restart the
ZeroTier service.</p>
<p>Moons belong in <code>/var/lib/zerotier-one/moons.d/</code>; orbit them with
<code>zerotier-cli orbit &lt;moonid&gt; &lt;moonid&gt;</code>.</p>
</body></html>
"""


def log(message):
    sys.stderr.write("planet-files: %s\n" % message)
    sys.stderr.flush()


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fp:
        for chunk in iter(lambda: fp.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def list_moons():
    try:
        names = [n for n in os.listdir(MOONS_DIR) if MOON_NAME_RE.match(n)]
    except OSError:
        return []
    return sorted(names)


class Handler(BaseHTTPRequestHandler):
    server_version = "planet-files/1.0"
    protocol_version = "HTTP/1.1"

    # ---------------------------------------------------------------- helpers
    def _authorized(self, query):
        if not TOKEN:
            return True
        supplied = (query.get("token") or [""])[0]
        if not supplied:
            header = self.headers.get("Authorization", "")
            if header.lower().startswith("bearer "):
                supplied = header[7:].strip()
        return hmac.compare_digest(supplied, TOKEN)

    def _send(self, code, body, content_type, extra_headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _unauthorized(self):
        body = b"401 unauthorized: a valid token is required\n"
        self._send(401, body, "text/plain; charset=utf-8", {"WWW-Authenticate": 'Bearer realm="planet"'})

    def _not_found(self, what):
        self._send(404, ("404 not found: %s\n" % what).encode(), "text/plain; charset=utf-8")

    def _serve_file(self, path, download_name):
        try:
            with open(path, "rb") as fp:
                body = fp.read()
        except OSError as exc:
            log("cannot read %s: %s" % (path, exc))
            self._not_found(download_name)
            return
        self._send(
            200,
            body,
            "application/octet-stream",
            {
                "Content-Disposition": 'attachment; filename="%s"' % download_name,
                "X-File-SHA256": hashlib.sha256(body).hexdigest(),
            },
        )

    def _index_page(self, query):
        token = (query.get("token") or [""])[0]
        suffix = ("?token=" + token) if token else ""
        moons = list_moons()
        rows = "".join(
            '<li><a href="/moon/%s%s">%s</a></li>' % (name, suffix, name) for name in moons
        ) or "<li><em>no moons yet</em></li>"
        planet_digest = "unavailable"
        try:
            planet_digest = sha256_of(PLANET_PATH)
        except OSError:
            pass
        # str.replace, not %/format: the page contains CSS braces and percent signs
        html = INDEX_TEMPLATE.replace("@@SUFFIX@@", suffix)
        html = html.replace("@@DIGEST@@", planet_digest)
        html = html.replace("@@ROWS@@", rows)
        self._send(200, html.encode(), "text/html; charset=utf-8")

    # ----------------------------------------------------------------- routes
    def do_GET(self):
        self._route()

    def do_HEAD(self):
        self._route()

    def _route(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = {}
        for part in parsed.query.split("&"):
            if not part:
                continue
            key, _, value = part.partition("=")
            query.setdefault(key, []).append(value)

        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
            return

        if not self._authorized(query):
            log("401 %s %s from %s" % (self.command, path, self.client_address[0]))
            self._unauthorized()
            return

        try:
            if path in ("/", "/index.html"):
                self._index_page(query)
            elif path == "/planet":
                self._serve_file(PLANET_PATH, "planet")
            elif path == "/moons":
                body = json.dumps({"moons": list_moons()}).encode()
                self._send(200, body, "application/json")
            elif path.startswith("/moon/"):
                name = path[len("/moon/"):]
                if not MOON_NAME_RE.match(name):
                    self._not_found(name)
                else:
                    self._serve_file(os.path.join(MOONS_DIR, name), name)
            else:
                self._not_found(path)
        except BrokenPipeError:
            pass
        except Exception as exc:  # never drop the connection without a response
            log("500 %s %s: %r" % (self.command, path, exc))
            try:
                self._send(500, ("500 internal error\n").encode(), "text/plain; charset=utf-8")
            except Exception:
                pass

    def log_message(self, fmt, *args):
        log("%s %s" % (self.client_address[0], fmt % args))


def main():
    os.chdir(ZT_HOME) if os.path.isdir(ZT_HOME) else None
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log("listening on 0.0.0.0:%d (token %s)" % (PORT, "required" if TOKEN else "disabled"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
