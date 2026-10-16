#!/usr/bin/env python3
"""Local synthetic API for MetadataAssistantUITests; never contacts music providers."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=18089)
parser.add_argument('--log', type=Path)
args = parser.parse_args()
recording_id = '11111111-1111-4111-8111-111111111111'
release_id = '22222222-2222-4222-8222-222222222222'
release = dict(id=release_id, title='Álbum de prueba QA', date='2026-01-02', country='ES', disambiguation='Edición de prueba')
recording = dict(id=recording_id, title='Luz sugerida QA', artist='Artista en línea QA',
                 duration_ms=30000, disambiguation='Grabación sintética de prueba', score=99,
                 releases=[release], genres=['Ambient'])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path)
        authorized = self.headers.get('Authorization') == 'Bearer sonora-ui-fixture-token'
        if args.log:
            with args.log.open('a') as log:
                log.write(json.dumps(dict(path=path.path, method='GET', authorized=authorized)) + '\n')
        if not authorized:
            return self.send(401, dict(error='unauthorized'))
        if path.path == '/v1/status':
            return self.send(200, dict(providers={name: dict(enabled=True, configured=name != 'acoustid') for name in ['acoustid', 'musicbrainz', 'lrclib', 'cover_art']}))
        if path.path == '/v1/recordings':
            return self.envelope([] if parse_qs(path.query).get('title') == ['Sin coincidencias QA'] else [recording])
        if path.path == '/v1/recordings/' + recording_id:
            return self.envelope(recording)
        if path.path == '/v1/releases/' + release_id:
            return self.envelope(dict(id=release_id, title=release['title'], date=release['date'],
                **{'artist-credit': [dict(name='Artista del álbum QA')], 'media': [dict(position=1,
                    **{'track-count': 3, 'tracks': [dict(position=1, title='Luz sugerida QA', recording=dict(id=recording_id))]})]}))
        if path.path == '/v1/lyrics':
            return self.envelope(dict(id=1, trackName=recording['title'], artistName=recording['artist'],
                albumName=release['title'], duration=30, instrumental=False, plainLyrics='Letra encontrada QA\nSegundo verso QA',
                syncedLyrics='[00:00]Letra encontrada QA\n[00:05]Segundo verso QA'))
        if path.path == '/v1/artwork/' + release_id:
            image = Path(__file__).resolve().parents[1] / 'Sonora/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
            return self.send(200, image.read_bytes(), 'image/png')
        return self.send(404, dict(error='not_found'))

    def envelope(self, value):
        return self.send(200, dict(sources=['https://musicbrainz.org/', 'https://lrclib.net/'], data=value))

    def send(self, status, value, content_type='application/json'):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
