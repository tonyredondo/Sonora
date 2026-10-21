#!/usr/bin/env python3
"""Cache a synthetic album reading after seed-lyrics-simulator and library indexing.

Only the marked Sonora Lyrics QA source and the unused UI-test endpoint are used.
No provider calls, production data, preferences or music files are changed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator', help='Simulator UDID; never a physical device')
args = parser.parse_args()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
container = Path(subprocess.check_output(
    ['xcrun', 'simctl', 'get_app_container', args.simulator, 'com.tonyredondo.Sonora', 'data'],
    env=env, text=True).strip())
root = container / 'Documents' / 'Sonora Lyrics QA'
if not (root / '.sonora-lyrics-qa').is_file():
    raise SystemExit('Missing marked synthetic lyrics folder')
prefs = plistlib.loads((container / 'Library/Preferences/com.tonyredondo.Sonora.plist').read_bytes())
collection = json.loads(prefs['musicCollection'])
sources = [s['id'] for s in collection['sources'] if s['name'] == 'Sonora Lyrics QA']
if len(sources) != 1:
    raise SystemExit('Index exactly one Sonora Lyrics QA source first')
songs = [dict(song, id=key) for key, song in collection['songs'].items() if song['sourceID'] == sources[0]]
for song in songs:
    tags = song['tags']
    song['tags'] = dict(zip(tags[::2], tags[1::2])) if isinstance(tags, list) else tags
    if song['tags'].get('album') != 'Letras en portada' or song['tags'].get('artist') != 'Sonora Tests' or song.get('cue'):
        raise SystemExit('Unexpected content in the synthetic source')
songs.sort(key=lambda s: s['relativePath'])
if len(songs) != 9:
    raise SystemExit('Index the nine synthetic lyric tracks first')
revision_input = [dict(id=s['id'], tags=s['tags'], modified=s['modified']) for s in songs]
# Swift's sorted JSON encoding also escapes slashes.
def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).replace('/', '\\/').encode()
revision = hashlib.sha256(encode(revision_input)).hexdigest()
tracks = []
for song in songs:
    audio = root / song['relativePath']
    if audio.parent != root or not audio.is_file():
        raise SystemExit('Missing synthetic audio file')
    text = ''
    sidecar = audio.with_suffix('.lrc')
    if sidecar.exists():
        import re
        text = '\n'.join(re.sub(r'^\[[^]]+\]', '', line) for line in sidecar.read_text().splitlines())
    elif song['relativePath'].startswith('01 -'):
        text = '\n'.join(f'Verso {n:02d} de la prueba de Sonora' for n in range(1, 41))
    tags = song['tags']
    tracks.append(dict(context=dict(title=tags['title'], artist=tags['artist'], album=tags['album'], styles=[], moods=[]), lyrics=text, genre=tags.get('genre', '')))
album = dict(title='Letras en portada', artist='Sonora Tests', tracks=tracks)
explanation = ('El disco recorre la espera, los encuentros y la ausencia. Las escenas cotidianas enlazan el paisaje con los vínculos personales: la mañana abre posibilidades y la noche invita a recordar.\n\n'
               'Las canciones ofrecen miradas distintas sobre el paso del tiempo. La esperanza de volver a empezar convive con la nostalgia por las personas que faltan. El conjunto puede leerse como un viaje entre la cercanía y la distancia.\n\n'
               'El cierre devuelve la atención a esos vínculos. Es una lectura del material disponible, sin atribuir una intención concreta a sus autores. Fin del álbum QA.')
prepared = dict(album=album, interpretation=dict(explanation=explanation, model='gpt-6-astra', effort='medium'))
album_id = 'sonora tests\0letras en portada'
cache = container / 'Library/Application Support/MusicTools/cache'
cache.mkdir(parents=True, exist_ok=True)
for character in ['true', 'false']:
    key = f'codex-album-v2:http://127.0.0.1:9:es:essentia-discogs-v1:{character}:{album_id}:{revision}'
    (cache / (hashlib.sha256(key.encode()).hexdigest() + '.json')).write_bytes(encode(prepared))
print('Seeded album QA cache for 9 indexed synthetic tracks; revision ' + revision[:12])
