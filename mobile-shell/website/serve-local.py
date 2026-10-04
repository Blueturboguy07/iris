#!/usr/bin/env python3
"""RC-03 (round5/rc03-website). Serves the built Iris Apps website on this
computer only, at http://127.0.0.1:8765/, so it can be clicked through
before anything is deployed. Standard library only, no install needed.

Unlike a bare "python3 -m http.server", a path with no matching file gets
the site's own not-found page (404.html) with a 404 status, the same way a
real visitor's mistyped or broken link should look, instead of the plain
default error page.

Run: python3 mobile-shell/website/serve-local.py
"""

import http.server
import os
import socketserver

HOST = "127.0.0.1"
PORT = 8765

HERE = os.path.dirname(os.path.abspath(__file__))
SITE_DIR = os.path.normpath(os.path.join(
    HERE,
    "..",
    "..",
    "docs",
    "plans",
    "20260928-all-routes",
    "round5",
    "rc03-website",
    "site",
))
NOT_FOUND_FILE = os.path.join(SITE_DIR, "404.html")


class NotFoundAwareHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SITE_DIR, **kwargs)

    def send_error(self, code, message=None, explain=None):
        if code == 404 and os.path.isfile(NOT_FOUND_FILE):
            with open(NOT_FOUND_FILE, "rb") as handle:
                body = handle.read()
            self.send_response(404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        super().send_error(code, message, explain)


def main():
    if not os.path.isdir(SITE_DIR):
        raise SystemExit(
            "the site has not been built yet; run "
            "node mobile-shell/website/build-site.mjs first"
        )
    with socketserver.TCPServer((HOST, PORT), NotFoundAwareHandler) as httpd:
        print(f"Serving {SITE_DIR}")
        print(f"Open http://{HOST}:{PORT}/iris/ in your browser")
        print("Press Control-C to stop.")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
