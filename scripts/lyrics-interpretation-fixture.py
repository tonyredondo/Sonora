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
album_ready = threading.Event()
album_input = None
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
        if self.path == '/release-album':
            album_ready.set()
            return self.send(200, {'released': True})
        if self.path == '/album-input':
            with lock:
                value = album_input
            return self.send(200, value)
        if self.path == '/release-translation':
            translation_ready.set()
            return self.send(200, {'released': True})
        if self.path == '/stats':
            with lock:
                value = dict(calls)
            return self.send(200, value)
        return self.send(404, {'error': 'fixture_route_not_found'})

    def do_POST(self):
        global album_input
        if self.path not in ('/v1/lyrics/interpret', '/v1/lyrics/translate', '/v1/albums/interpret'):
            return self.send(404, {'error': 'fixture_route_not_found'})
        if self.headers.get('Authorization') != 'Bearer sonora-carousel-fixture-token':
            return self.send(401, {'error': 'fixture_token_required'})
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 2 * 1024 * 1024:
            return self.send(400, {'error': 'invalid_fixture_body'})
        data = json.loads(self.rfile.read(size))
        if self.path != '/v1/lyrics/translate' and data.get('effort') != 'medium':
            return self.send(400, {'error': 'fixture_requires_medium'})
        if self.path == '/v1/albums/interpret':
            album = data.get('album', {})
            tracks = album.get('tracks', [])
            if (album.get('title') != 'Letras en portada' or album.get('artist') != 'Sonora Tests'
                    or len(tracks) != 9 or any('QA' not in t.get('context', {}).get('title', '') for t in tracks)):
                return self.send(503, {'error': 'codex_disabled'})
            with lock:
                album_input = data
                calls['album'] += 1
            if not album_ready.wait(timeout=120):
                return self.send(504, {'error': 'codex_timeout'})
            return self.send(200, {'explanation': 'Interpretación del álbum QA preparada automáticamente. El conjunto explora la espera, los encuentros y la ausencia.',
                                   'model': 'gpt-6-astra', 'effort': 'medium'})
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
                                   'model': 'gpt-6.1-sol', 'effort': 'medium'})
        # Only the explicitly marked synthetic seed files are accepted.
        first = data.get('lyrics', '').split('\n')[0]
        if first != 'Línea sincronizada 00':
            return self.send(503, {'error': 'codex_disabled'})
        with lock:
            calls['synced'] += 1
        if not ready.wait(timeout=120):
            return self.send(504, {'error': 'codex_timeout'})
        return self.send(200, {'explanation': 'Interpretación preparada para la prueba. El contenido aparece automáticamente al terminar el trabajo en cola.',
                               'model': 'gpt-6-astra', 'effort': 'medium'})


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
    album_ready.set()
    server.server_close()
