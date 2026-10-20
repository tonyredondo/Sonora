#!/usr/bin/env python3
"""Seed isolated synthetic lyrics fixtures in one simulator's Sonora container."""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator', help='Simulator UDID; never a physical device')
args = parser.parse_args()
env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
container = Path(subprocess.check_output(
    ['xcrun', 'simctl', 'get_app_container', args.simulator, 'com.tonyredondo.Sonora', 'data'],
    env=env, text=True).strip())
root = container / 'Documents' / 'Sonora Lyrics QA'
marker = root / '.sonora-lyrics-qa'
if root.exists() and not marker.exists():
    raise SystemExit('Refusing to overwrite an unmarked folder: ' + str(root))
root.mkdir(parents=True, exist_ok=True)
marker.write_text('Synthetic, regenerable lyrics fixtures. No user music.\n')
for number, title in [(1, 'Letra completa QA'), (2, 'Letra sincronizada QA'), (3, 'Sin letra QA'), (4, 'Pulso 120 BPM QA'), (5, 'Dinámica 120 BPM QA'), (6, 'Traducción contextual QA'), (7, 'Traducción por frases QA'), (8, 'Última traducción QA'), (9, 'Pulso 180 BPM QA')]:
    source = f'sine=frequency={220 * number}:sample_rate=44100:duration=180'
    if number == 4:
        source = r'aevalsrc=0.12*sin(2*PI*880*t)*(0.04+0.96*lt(mod(t\,0.5)\,0.025)):s=44100:d=180'
    if number == 9:
        source = r'aevalsrc=0.12*sin(2*PI*880*t)*(0.04+0.96*lt(mod(t\,1/3)\,0.025)):s=44100:d=24'
    if number == 5:
        # Quiet intro, build, breakdown, loud passage and fade at the same tempo.
        envelope = r'if(lt(t\,12)\,0.07\,if(lt(t\,20)\,0.07+0.43*(t-12)/8\,if(lt(t\,32)\,0.5\,if(lt(t\,44)\,0.12\,if(lt(t\,68)\,0.8\,0.8*(80-t)/12)))))'
        source = rf'aevalsrc=sin(2*PI*220*t)*(0.35+0.65*lt(mod(t\,0.5)\,0.06))*{envelope}:s=44100:d=80'
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
               source,
               '-ac', '2', '-c:a', 'flac', '-metadata', 'title=' + title,
               '-metadata', 'artist=Sonora Tests', '-metadata', 'album=Letras en portada']
    if number == 1:
        command += ['-metadata', 'lyrics=' + '\n'.join(f'Verso {n:02d} de la prueba de Sonora' for n in range(1, 41))]
    subprocess.run(command + [str(root / f'{number:02d} - {title}.flac')], check=True)
(root / '02 - Letra sincronizada QA.lrc').write_text(
    '\n'.join(f'[00:{n:02d}]Línea sincronizada {n:02d}' for n in range(40)), encoding='utf-8')
# Synthetic per-line translations exercise rendering and persistent cache restoration.
# Provider quality is validated separately against the real Codex worker.
cache = container / 'Library' / 'Application Support' / 'MusicTools' / 'cache'
cache.mkdir(parents=True, exist_ok=True)
translations = [
    ('06 - Traducción contextual QA', [1, 3, 7, 9],
     ['When the rain finally stops', 'we will go outside.'] * 2,
     ['Cuando finalmente deje de llover,', 'saldremos.'] * 2),
    ('07 - Traducción por frases QA', [1, 3, 6, 9, 12, 15],
     ['The sun rises over the mountains', 'A bird sings in the garden', 'The train arrives at noon',
      'We will meet by the river', 'The evening brings a gentle breeze', 'Tomorrow we begin again'],
     ['El sol sale sobre las montañas.', 'Un pájaro canta en el jardín.', 'El tren llega al mediodía.',
      'Nos encontraremos junto al río.', 'La noche trae una suave brisa.', 'Mañana comenzamos de nuevo.']),
    ('08 - Última traducción QA', [1, 3, 6, 9, 12, 15],
     ['I miss everyone', 'of you', 'I miss everyone', 'I miss everyone', 'I miss everyone', 'and you'],
     ['Echo de menos a todos,', 'vosotros', 'echo de menos a todos,', 'echo de menos a todos,',
      'echo de menos a todos', 'y a ti'])
]
for title, times, text, translated in translations:
    (root / (title + '.lrc')).write_text(
        '\n'.join(f'[00:{time:02d}]{line}' for time, line in zip(times, text)), encoding='utf-8')
    source = json.dumps([dict(id=i, text=line) for i, line in enumerate(text)], sort_keys=True, separators=(',', ':'))
    key = 'codex-translation-v1:gpt-6.1-sol:medium:auto:es:' + hashlib.sha256(source.encode()).hexdigest()
    value = dict(lines={str(i): line for i, line in enumerate(translated)})
    (cache / (hashlib.sha256(key.encode()).hexdigest() + '.json')).write_text(json.dumps(value), encoding='utf-8')
    if title.startswith('06'):
        # The loopback loading-state test uses explicit English, separate from
        # these offline display fixtures. Reset only that synthetic cached result.
        live_key = key.replace(':auto:es:', ':en:es:')
        previous_live_key = live_key.replace(':gpt-6.1-sol:medium:', ':gpt-6-astra:xhigh:')
        for cached_key in [live_key, previous_live_key]:
            (cache / (hashlib.sha256(cached_key.encode()).hexdigest() + '.json')).unlink(missing_ok=True)
    # Offline interpretation fixtures, scoped to the UI tests' unused loopback
    # endpoint. No live provider or account is needed to inspect the carousel.
    meaning_cache = container / 'Library' / 'Application Support' / 'Sonora' / 'MetadataCache'
    meaning_cache.mkdir(parents=True, exist_ok=True)
    request = json.dumps(dict(language='es', lyrics='\n'.join(text)),
                         ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    meaning_key = 'codex-meaning-v1:gpt-6-astra:xhigh:http://127.0.0.1:9:' + hashlib.sha256(request.encode()).hexdigest()
    explanation = ('La canción observa los pequeños cambios del día: la luz, los encuentros y la calma de la noche. '
                   'El paisaje acompaña una sensación de esperanza y de empezar de nuevo.\n\n'
                   'Las imágenes del camino y del río pueden leerse como momentos compartidos. '
                   'No afirman una intención del autor; esta es una lectura posible del texto.\n\n'
                   'El cierre invita a mirar hacia el mañana. Fin de la interpretación QA.')
    if title.startswith('08'):
        explanation = 'La repetición expresa la ausencia de varias personas y termina dirigiéndose a una en particular. Significado de la última traducción QA.'
    body = json.dumps(dict(explanation=explanation, model='gpt-6-astra', effort='xhigh'), ensure_ascii=False).encode()
    entry = dict(data=body, status=200, savedAt=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), key=meaning_key)
    (meaning_cache / (hashlib.sha256(meaning_key.encode()).hexdigest() + '.plist')).write_bytes(
        plistlib.dumps(entry, fmt=plistlib.FMT_BINARY))
icon = Path(__file__).resolve().parents[1] / 'Sonora/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
shutil.copyfile(icon, root / 'cover.png')
print(root)
