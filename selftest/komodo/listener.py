"""Stand-in Komodo listener for the selftest. Checks what the
komodo-deploy action posts, the way the real listener does, and records the
verdict of the last request in the file named by argv[1]."""

import hashlib
import hmac
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = b"selftest-secret"
PATH = "/listener/github/stack/selftest/deploy"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        want = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        ok = (
            self.path == PATH
            and self.headers.get("X-GitHub-Event") == "push"
            and hmac.compare_digest(self.headers.get("X-Hub-Signature-256", ""), want)
            and json.loads(body) == {"ref": "refs/heads/main"}
        )
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok\n" if ok else b"bad signature\n")
        with open(sys.argv[1], "w") as f:
            f.write("ok" if ok else "bad")


HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
