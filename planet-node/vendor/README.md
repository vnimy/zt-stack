# vendor/

Vendored third-party sources, kept in-tree so the image builds and runs without
network access and without adding a pip dependency to the runtime image.

## qrcodegen.py

| item | value |
| --- | --- |
| upstream | https://github.com/nayuki/QR-Code-generator |
| file | `python/qrcodegen.py` (master, fetched 2026-11-11) |
| download URL | `https://raw.githubusercontent.com/nayuki/QR-Code-generator/master/python/qrcodegen.py` |
| version | master as of 2026-11-11 (no tagged release in the upstream Python tree) |
| license | MIT — the full text is in the file header, original copyright intact |
| size | 39,349 bytes |
| sha256 | `9f4ed1dd201dcb92b1bc0d6e14f46c754bcff0ce48580c5d7e8ace8f6926c8ef` |

Why vendored: `planet-files.py` renders the planet URL as an SVG QR code for the
download page (`/qr.svg`). The runtime image is a slim Ubuntu with Python 3.12
and has no QR library, and adding `qrcodegen` from PyPI would mean a network
fetch at build time plus a moving dependency for a 40 KB pure-Python file.

How it is used: `planet-files.py` does `import qrcodegen` and only needs
`QrCode.encode_text(text, Ecc.MEDIUM)` and `get_module(x, y)` / `get_size()`.
The module is copied next to the script in the container
(`./qrcodegen.py:/usr/local/bin/qrcodegen.py:ro`), so it lands on the script's
own `sys.path[0]`. If the import fails, the download page silently hides the QR
block and `/qr.svg` answers 503 — the rest of the service keeps working.

Verification: the SVG `path` produced by `qr_svg()` was parsed back into a module
matrix and compared with `qrcodegen`'s own matrix for three payloads (match OK),
and a PNG rendered from the same module was decoded with `zxing-cpp` (4/4 OK).
