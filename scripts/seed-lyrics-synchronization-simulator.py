#!/usr/bin/env python3
"""Seed marked synthetic audio and a test-only proxy connection in one simulator."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator')
parser.add_argument('--scenario', choices=['synchronization', 'repair'], default='synchronization')
parser.add_argument('--endpoint', default='http://127.0.0.1:18093')
args = parser.parse_args()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator, 'com.tonyredondo.Sonora', 'data'], env=env, text=True).strip())
root = container / ('Documents/Sonora Repair QA' if args.scenario == 'repair' else 'Documents/Sonora Sync QA')
marker = root / '.sonora-sync-qa'
if root.exists() and not marker.exists():
    raise SystemExit('Refusing to overwrite an unmarked QA folder')
root.mkdir(parents=True, exist_ok=True)
# Keep each seeded run independent of earlier immutable audio analyses without
# clearing any app cache. The samples remain stable across that run's relaunches.
run_id = uuid.uuid4().hex
frequency = 300 + (int(run_id, 16) % 1_000_000_000) / 10_000_000
marker.write_text(f'Synthetic, regenerable synchronization fixtures. Run {run_id}, tone {frequency:.7f} Hz.\n')
tracks = [(1, 'Reparación QA'), (2, 'Letra mixta QA')] if args.scenario == 'repair' else [(1, 'Catálogo sincronizado QA'), (2, 'Tiempos Eleven QA'), (3, 'Sin letra IA QA')]
for index, title in tracks:
    lyrics = ({1: '[ar:Sonora Tests]\n[00:01.00]Camino de cristel\n[00:10.00]\n[00:16.00]Volvemos al hogar',
               2: '[00:01.00]Una frase con tiempos\nOtra frase sin tiempos'}[index] if args.scenario == 'repair' else
              {1: 'Primera línea de Sonora\nSegunda línea de Sonora', 2: 'Mi letra de prueba\nMi letra se repite',
               3: '[ar:Sonora Tests]\n[ti:Sin letra IA QA]'}.get(index, ''))
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', f'sine=frequency={frequency:.7f}:sample_rate=44100:duration=30', '-ac', '2', '-c:a', 'flac', '-metadata', 'title=' + title, '-metadata', 'artist=Sonora Tests', '-metadata', 'album=Sincronización QA', '-metadata', 'lyrics=' + lyrics, str(root / f'{index:02d} - {title}.flac')], check=True)
support = container / 'Library/Application Support/Sonora'
support.mkdir(parents=True, exist_ok=True)
bootstrap = support / 'ProxyConnection.json'
if bootstrap.exists():
    raise SystemExit('A pending proxy connection already exists; inspect it before replacing')
bootstrap.write_text(json.dumps({'endpoint': args.endpoint, 'token': 'sonora-sync-fixture-token'}))
print(root)
