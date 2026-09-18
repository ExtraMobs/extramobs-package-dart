"""Serve a private JSON config once over adb reverse; never log credentials."""
import http.server
import pathlib
import secrets
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
token = '/' + secrets.token_urlsafe(24)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != token:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass

with http.server.HTTPServer(('127.0.0.1', 38765), Handler) as server:
    server.timeout = 300
    print('http://127.0.0.1:38765' + token, flush=True)
    server.handle_request()
