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
parser.add_argument('--scenario', choices=['synchronization', 'repair'], default='synchronization')
parser.add_argument('--failure', choices=['quota'], default=None)
args = parser.parse_args()
counts = {'catalog': 0, 'alignment': 0, 'transcription': 0}
state = {'failure': args.failure}
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
        if self.path == '/__failure':
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 128:
                return self.reply(400, {})
            mode = self.rfile.read(size).decode()
            if mode not in ('quota', 'none'):
                return self.reply(400, {})
            state['failure'] = None if mode == 'none' else mode
            return self.reply(200, {})
        if self.path not in ('/v1/forced-alignment', '/v1/speech-to-text') or self.headers.get('xi-api-key') != 'synthetic-eleven-key':
            return self.reply(401, {})
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 20_000_000:
            return self.reply(413, {})
        message = BytesParser(policy=default).parsebytes(('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + self.rfile.read(size))
        fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True) for part in message.iter_parts()}
        if self.path == '/v1/speech-to-text':
            expected = {'model_id': b'scribe_v2', 'timestamps_granularity': b'word',
                        'tag_audio_events': b'false', 'diarize': b'false'}
            if set(fields) != {'file', *expected} or not fields['file'].startswith(b'RIFF') or any(fields[key] != value for key, value in expected.items()):
                return self.reply(400, {})
            counts['transcription'] += 1
            if state['failure'] == 'quota':
                return self.reply(429, {'detail': {'status': 'quota_exceeded', 'message': 'private-lyrics synthetic-eleven-key'}})
            if args.scenario == 'repair':
                transcript = 'Camino de cristal.\nVuelve la luz.\nVolvemos al hogar.'
                words = []
                for start, line in [(1, 'Camino de cristal.'), (8, 'Vuelve la luz.'), (16, 'Volvemos al hogar.')]:
                    for index, word in enumerate(line.split()):
                        words.append({'text': word, 'start': start + index * 0.4, 'end': start + index * 0.4 + 0.3, 'type': 'word'})
                return self.reply(200, {'text': transcript, 'language_code': 'spa', 'words': words})
            transcript = 'Primera\u2028frase inventada. Segunda frase inventada.'
            return self.reply(200, {'text': transcript, 'language_code': 'spa',
                'words': [{'text': word, 'start': 1 + (index // 3) * 7 + (index % 3) * 0.3, 'end': 1.2 + (index // 3) * 7 + (index % 3) * 0.3, 'type': 'word'}
                          for index, word in enumerate(transcript.split())]})
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
