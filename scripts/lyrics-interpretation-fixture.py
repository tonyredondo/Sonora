#!/usr/bin/env python3
"""Bounded localhost fixture for carousel loading/ready tests; no AI provider."""
import argparse
import json
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=18096)
args = parser.parse_args()
ready = threading.Event()
translation_ready = threading.Event()
calls = Counter()
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/release':
            ready.set()
            return self.send(200, {'released': True})
        if self.path == '/release-translation':
            translation_ready.set()
            return self.send(200, {'released': True})
        if self.path == '/stats':
            with lock:
                value = dict(calls)
            return self.send(200, value)
        return self.send(404, {'error': 'fixture_route_not_found'})

    def do_POST(self):
        if self.path not in ('/v1/lyrics/interpret', '/v1/lyrics/translate'):
            return self.send(404, {'error': 'fixture_route_not_found'})
        if self.headers.get('Authorization') != 'Bearer sonora-carousel-fixture-token':
            return self.send(401, {'error': 'fixture_token_required'})
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 65536:
            return self.send(400, {'error': 'invalid_fixture_body'})
        data = json.loads(self.rfile.read(size))
        if self.path == '/v1/lyrics/translate':
            lines = data.get('lines', [])
            if (len(lines) != 4 or
                    [line.get('text') for line in lines] !=
                    ['When the rain finally stops', 'we will go outside.'] * 2 or
                    data.get('source_language') != 'en' or data.get('target_language') != 'es'):
                return self.send(503, {'error': 'codex_disabled'})
            with lock:
                calls['translated'] += 1
            if not translation_ready.wait(timeout=120):
                return self.send(504, {'error': 'codex_timeout'})
            translated = ['Cuando por fin pare la lluvia,', 'saldremos a la calle.'] * 2
            return self.send(200, {'lines': [{'id': line['id'], 'text': text}
                                            for line, text in zip(lines, translated)],
                                   'model': 'gpt-6-astra', 'effort': 'xhigh'})
        # Only the explicitly marked synthetic seed files are accepted.
        first = data.get('lyrics', '').split('\n')[0]
        if first != 'Línea sincronizada 00':
            return self.send(503, {'error': 'codex_disabled'})
        with lock:
            calls['synced'] += 1
        if not ready.wait(timeout=120):
            return self.send(504, {'error': 'codex_timeout'})
        return self.send(200, {'explanation': 'Interpretación preparada para la prueba. El contenido aparece automáticamente al terminar el trabajo en cola.',
                               'model': 'gpt-6-astra', 'effort': 'xhigh'})


server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
server.timeout = 1
server.daemon_threads = True
deadline = time.monotonic() + 300
try:
    while time.monotonic() < deadline:
        server.handle_request()
finally:
    ready.set()
    translation_ready.set()
    server.server_close()
