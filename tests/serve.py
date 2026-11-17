"""Serves a directory the way https://app.valarhq.ai/cli serves the latest release: scripts as
text/plain, release.json as JSON, binaries as octet-stream, and 404 for anything missing.

Usage: python tests/serve.py <dir> <port>
"""

import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        ".ps1": "text/plain; charset=utf-8",
        ".sh": "text/plain; charset=utf-8",
        ".txt": "text/plain; charset=utf-8",
        ".sig": "text/plain; charset=utf-8",
        ".json": "application/json",
        ".bundle": "application/json",
        "": "application/octet-stream",
    }

    def guess_type(self, path):
        for ext, ctype in self.extensions_map.items():
            if ext and str(path).endswith(ext):
                return ctype
        return "application/octet-stream"


http.server.ThreadingHTTPServer(
    ("127.0.0.1", int(sys.argv[2])), functools.partial(Handler, directory=sys.argv[1])
).serve_forever()
