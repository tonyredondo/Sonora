#!/usr/bin/env python3
"""Local LRCLIB/ElevenLabs contract fixture. Receives synthetic QA audio only."""
import argparse
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from urllib.parse import parse_qs, urlparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=18092)
args = parser.parse_args()
counts = {'catalog': 0, 'alignment': 0}
text = 'Primera línea de Sonora\nSegunda línea de Sonora'
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def reply(self, status, body):
        encoded = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == '/__stats':
            return self.reply(200, counts)
        if url.path != '/api/get':
            return self.reply(404, {})
        counts['catalog'] += 1
        query = parse_qs(url.query)
        if query.get('track_name') != ['Catálogo sincronizado QA']:
            return self.reply(404, {})
        self.reply(200, {'id': 77, 'trackName': 'Catálogo sincronizado QA', 'artistName': 'Sonora Tests',
                        'albumName': 'Sincronización QA', 'duration': 30, 'instrumental': False,
                        'plainLyrics': text, 'syncedLyrics': '[00:01.00]Primera línea de Sonora\n[00:08.00]Segunda línea de Sonora'})
    def do_POST(self):
        if self.path != '/v1/forced-alignment' or self.headers.get('xi-api-key') != 'synthetic-eleven-key':
            return self.reply(401, {})
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 20_000_000:
            return self.reply(413, {})
        message = BytesParser(policy=default).parsebytes(('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + self.rfile.read(size))
        fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True) for part in message.iter_parts()}
        if set(fields) != {'file', 'text'} or not fields['file'].startswith(b'RIFF'):
            return self.reply(400, {})
        counts['alignment'] += 1
        words = []
        for index, line in enumerate(fields['text'].decode().splitlines()):
            for number, word in enumerate(line.split()):
                start = 1 + index * 7 + number * 0.2
                words.append({'text': word, 'start': start, 'end': start + 0.15})
        self.reply(200, {'words': words, 'characters': [], 'loss': 0.1})

print(f'Synthetic lyric providers listening on 127.0.0.1:{args.port}', flush=True)
ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
