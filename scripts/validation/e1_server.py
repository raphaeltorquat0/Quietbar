#!/usr/bin/env python3
"""Serve a página do E1 em localhost (contexto seguro para getUserMedia) e grava as fases em JSONL."""
import http.server, json, sys, time, urllib.parse

page = open(sys.argv[2], "rb").read()
log = open(sys.argv[3], "a", buffering=1)


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/phase":
            q = urllib.parse.parse_qs(u.query)
            log.write(json.dumps({"t": int(time.time() * 1000), "kind": "phase", "name": q["name"][0], "extra": q.get("extra", [""])[0]}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        if u.path == "/":
            self.wfile.write(page)

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
