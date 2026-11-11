#!/usr/bin/env python3
"""Read-only download service for a self-hosted ZeroTier planet.

Serves, out of /var/lib/zerotier-one:
  GET /healthz        liveness, always unauthenticated
  GET /planet         the planet (world) file, X-File-SHA256 carries its digest
  GET /moons          JSON list of moon file names
  GET /moon/<name>    one moon file
  GET /version.json   latest client build info, read from $ZT_HOME/version.json
  GET /app/zerotierfix.apk
                      latest Android build, read from $ZT_HOME/zerotierfix.apk
  GET /qr.svg         QR code (SVG) of the planet URL, for the Android client's
                      "import from QR code"; ?path=/app/zerotierfix.apk for the APK
  GET /               tiny HTML index page, Chinese by default; ?lang=en switches
                      to English and remembers the choice in a cookie

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
from urllib.parse import quote, unquote, urlparse

try:  # vendored next to this file; only /qr.svg needs it
    import qrcodegen
except ImportError:  # pragma: no cover - the page hides the QR block instead
    qrcodegen = None

ZT_HOME = os.environ.get("ZT_HOME", "/var/lib/zerotier-one")
PLANET_PATH = os.path.join(ZT_HOME, "planet")
MOONS_DIR = os.path.join(ZT_HOME, "moons.d")
VERSION_PATH = os.path.join(ZT_HOME, "version.json")
APP_APK_PATH = os.path.join(ZT_HOME, "zerotierfix.apk")
TOKEN = os.environ.get("DOWNLOAD_TOKEN", "")
PORT = int(os.environ.get("FILES_PORT", "3000"))

MOON_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.moon$")

INDEX_TEMPLATE = """<!doctype html>
<html lang="@@LANG@@"><head><meta charset="utf-8"><title>@@TITLE@@</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui,sans-serif;margin:2rem;max-width:48rem}
code{background:#f2f2f2;padding:.1rem .3rem;border-radius:3px}
.nav{margin:0 0 1rem;font-size:.9rem;text-align:right}
.nav a{text-decoration:none}
.qr{display:flex;gap:1.5rem;align-items:flex-start;flex-wrap:wrap;margin:1rem 0}
.qr img{width:200px;height:200px;border:1px solid #ddd;border-radius:6px;background:#fff}</style></head>
<body>
<p class="nav"><a href="@@HREF_ZH@@">&#20013;&#25991;</a> &middot; <a href="@@HREF_EN@@">English</a></p>
<h1>@@H1@@</h1>
<ul>
<li><a href="/planet@@SUFFIX@@">planet</a> @@PLANET_NOTE@@</li>
<li><a href="/moons@@SUFFIX@@">moons</a> @@MOONS_NOTE@@</li>
<li><a href="/app/zerotierfix.apk@@SUFFIX@@">@@APP_LINK@@</a> @@APP_NOTE@@</li>
</ul>
<h2>@@H2_APP@@</h2>
<p>@@APP_VERSION@@ &middot; <a href="/app/zerotierfix.apk@@SUFFIX@@">@@DOWNLOAD@@</a></p>
<div class="qr">
@@QR_BLOCK@@
<div>
<p>@@SCAN@@</p>
<p>@@CARRIES@@</p>
</div>
</div>
<h2>@@H2_MOONS@@</h2>
<ul>@@ROWS@@</ul>
<h2>@@H2_SETUP@@</h2>
<p>@@SETUP1@@</p>
<p>@@SETUP2@@</p>
</body></html>
"""

# Page strings. Keys shared by both languages; {digest}/{url} are filled in
# with str.replace so CSS braces and percent signs elsewhere stay untouched.
STRINGS = {
    "zh": {
        "title": "ZeroTier 行星节点",
        "h1": "ZeroTier 行星节点",
        "planet_note": "（world 文件，sha256 <code>{digest}</code>）",
        "moons_note": "（JSON 列表）",
        "app_link": "Android 客户端",
        "app_note": "（ZerotierFix APK）",
        "h2_app": "Android 客户端",
        "app_version_fallback": "未发布",
        "download": "下载",
        "scan": "用 App 扫码：<b>设置 &rarr; 行星服务器 &rarr; 扫描二维码导入</b>。",
        "carries": "二维码内容为 <code>{url}</code>。",
        "h2_moons": "Moons",
        "no_moons": "暂无 moon",
        "h2_setup": "客户端接入",
        "setup1": "把 <code>planet</code> 放到客户端的 <code>/var/lib/zerotier-one/planet</code>"
        "（Windows 为 <code>&#37;LOCALAPPDATA&#37;\\ZeroTier\\One\\planet</code>），然后重启 ZeroTier 服务。",
        "setup2": "moon 文件放到 <code>/var/lib/zerotier-one/moons.d/</code>，用"
        " <code>zerotier-cli orbit &lt;moonid&gt; &lt;moonid&gt;</code> 加入轨道。",
        "qr_missing": "二维码支持未安装。",
    },
    "en": {
        "title": "ZeroTier planet node",
        "h1": "ZeroTier planet node",
        "planet_note": "(world file, sha256 <code>{digest}</code>)",
        "moons_note": "(JSON list)",
        "app_link": "Android client",
        "app_note": "(ZerotierFix APK)",
        "h2_app": "Android client",
        "app_version_fallback": "not published",
        "download": "download",
        "scan": "Scan with the app: <b>Settings &rarr; Planet server &rarr; Import from QR code</b>.",
        "carries": "The code carries <code>{url}</code>.",
        "h2_moons": "Moons",
        "no_moons": "no moons yet",
        "h2_setup": "Client setup",
        "setup1": "Drop <code>planet</code> into <code>/var/lib/zerotier-one/planet</code> on the client"
        " (<code>&#37;LOCALAPPDATA&#37;\\ZeroTier\\One\\planet</code> on Windows) and restart the"
        " ZeroTier service.",
        "setup2": "Moons belong in <code>/var/lib/zerotier-one/moons.d/</code>; orbit them with"
        " <code>zerotier-cli orbit &lt;moonid&gt; &lt;moonid&gt;</code>.",
        "qr_missing": "QR support not installed.",
    },
}
DEFAULT_LANG = "zh"


def log(message):
    sys.stderr.write("planet-files: %s\n" % message)
    sys.stderr.flush()


def human_size(num):
    value = float(num)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return "%d B" % value if unit == "B" else "%.1f %s" % (value, unit)
        value /= 1024.0
    return "%d B" % num


def qr_svg(text, scale=6, border=4):
    """Render text as an SVG QR code (vector, no extra dependencies)."""
    code = qrcodegen.QrCode.encode_text(text, qrcodegen.QrCode.Ecc.MEDIUM)
    size = code.get_size()
    dimension = (size + 2 * border) * scale
    runs = []
    for y in range(size):
        x = 0
        while x < size:
            if not code.get_module(x, y):
                x += 1
                continue
            run = 1
            while x + run < size and code.get_module(x + run, y):
                run += 1
            runs.append(
                "M%d %dh%dv%dh-%dz"
                % ((x + border) * scale, (y + border) * scale, run * scale, scale, run * scale)
            )
            x += run
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"'
        ' shape-rendering="crispEdges">'
        '<rect width="100%%" height="100%%" fill="#ffffff"/>'
        '<path d="%s" fill="#000000"/></svg>'
        % (dimension, dimension, dimension, dimension, "".join(runs))
    )


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

    def _serve_version(self):
        """Serve $ZT_HOME/version.json, the client update manifest.

        The file is read on every request so bumping it needs no restart:
          {"versionCode": 15, "versionName": "1.0.11", "url": "https://...", "notes": "..."}
        """
        try:
            with open(VERSION_PATH, "rb") as fp:
                body = fp.read()
        except OSError:
            self._not_found("version.json (not installed)")
            return
        try:
            data = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            log("invalid %s: %s" % (VERSION_PATH, exc))
            self._send(500, b"500 version.json is not valid JSON\n", "text/plain; charset=utf-8")
            return
        if not isinstance(data, dict) or not isinstance(data.get("versionCode"), int):
            self._send(500, b"500 version.json needs an integer versionCode\n", "text/plain; charset=utf-8")
            return
        self._send(200, json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def _public_base(self):
        """scheme://host as the browser or proxy sees us, for links and QR codes."""
        proto = (self.headers.get("X-Forwarded-Proto") or "http").split(",")[0].strip().lower()
        host = (self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or "").split(",")[0].strip()
        if not host:
            host = "127.0.0.1:%d" % PORT
        return "%s://%s" % (proto or "http", host)

    def _serve_qr(self, query):
        if qrcodegen is None:
            self._send(503, b"503 QR support is not installed\n", "text/plain; charset=utf-8")
            return
        path = (query.get("path") or ["/planet"])[0]
        if path not in ("/planet", "/app/zerotierfix.apk"):
            self._send(400, b"400 path must be /planet or /app/zerotierfix.apk\n", "text/plain; charset=utf-8")
            return
        url = self._public_base() + path
        token = (query.get("token") or [""])[0]
        if token:
            url += "?token=" + quote(token, safe="")
        self._send(200, qr_svg(url).encode("utf-8"), "image/svg+xml; charset=utf-8")

    def _cookie_lang(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            key, _, value = part.strip().partition("=")
            if key == "lang" and value.strip() in STRINGS:
                return value.strip()
        return DEFAULT_LANG

    def _index_page(self, query):
        token = (query.get("token") or [""])[0]
        wanted = (query.get("lang") or [""])[0].strip().lower()
        lang = wanted if wanted in STRINGS else self._cookie_lang()
        text = STRINGS[lang]
        suffix = ("?token=" + token) if token else ""

        def lang_href(target):
            pairs = []
            if token:
                pairs.append("token=" + quote(token, safe=""))
            pairs.append("lang=" + target)
            return "?" + "&".join(pairs)

        moons = list_moons()
        rows = "".join(
            '<li><a href="/moon/%s%s">%s</a></li>' % (name, suffix, name) for name in moons
        ) or "<li><em>%s</em></li>" % text["no_moons"]
        planet_digest = "unavailable"
        try:
            planet_digest = sha256_of(PLANET_PATH)
        except OSError:
            pass
        info = None
        try:
            with open(VERSION_PATH, "rb") as fp:
                info = json.loads(fp.read().decode("utf-8"))
            if not (isinstance(info, dict) and isinstance(info.get("versionCode"), int)):
                info = None
        except (OSError, ValueError, UnicodeDecodeError):
            info = None
        if info is None:
            app_version = text["app_version_fallback"]
        else:
            app_version = "%s (code %d)" % (info.get("versionName") or "?", info["versionCode"])
        try:
            app_version += " &middot; %s" % human_size(os.path.getsize(APP_APK_PATH))
        except OSError:
            pass
        planet_url = self._public_base() + "/planet"
        if token:
            planet_url += "?token=" + quote(token, safe="")
        if qrcodegen is None:
            qr_block = "<p><em>%s</em></p>" % text["qr_missing"]
        else:
            qr_block = '<img src="/qr.svg%s" width="200" height="200" alt="planet QR code">' % suffix
        # str.replace, not %/format: the page contains CSS braces and percent signs
        html = INDEX_TEMPLATE
        replacements = (
            ("@@LANG@@", "zh-CN" if lang == "zh" else "en"),
            ("@@TITLE@@", text["title"]),
            ("@@H1@@", text["h1"]),
            ("@@HREF_ZH@@", lang_href("zh")),
            ("@@HREF_EN@@", lang_href("en")),
            ("@@SUFFIX@@", suffix),
            ("@@PLANET_NOTE@@", text["planet_note"].replace("{digest}", planet_digest)),
            ("@@MOONS_NOTE@@", text["moons_note"]),
            ("@@APP_LINK@@", text["app_link"]),
            ("@@APP_NOTE@@", text["app_note"]),
            ("@@H2_APP@@", text["h2_app"]),
            ("@@APP_VERSION@@", app_version),
            ("@@DOWNLOAD@@", text["download"]),
            ("@@SCAN@@", text["scan"]),
            ("@@ROWS@@", rows),
            ("@@H2_MOONS@@", text["h2_moons"]),
            ("@@H2_SETUP@@", text["h2_setup"]),
            ("@@SETUP1@@", text["setup1"]),
            ("@@SETUP2@@", text["setup2"]),
        )
        for key, value in replacements:
            html = html.replace(key, value)
        # Filled last: their values may contain strings that look like tokens.
        html = html.replace("@@PLANET_URL@@", planet_url)
        html = html.replace("@@CARRIES@@", text["carries"].replace("{url}", planet_url))
        html = html.replace("@@QR_BLOCK@@", qr_block)
        headers = {}
        if wanted in STRINGS:
            headers["Set-Cookie"] = "lang=%s; Path=/; Max-Age=31536000; SameSite=Lax" % lang
        self._send(200, html.encode(), "text/html; charset=utf-8", headers)

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
            elif path == "/version.json":
                self._serve_version()
            elif path == "/qr.svg":
                self._serve_qr(query)
            elif path == "/app/zerotierfix.apk":
                self._serve_file(APP_APK_PATH, "zerotierfix.apk")
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
