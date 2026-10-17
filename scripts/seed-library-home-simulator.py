#!/usr/bin/env python3
"""Create marked synthetic source-management fixtures on one named Simulator."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator', help='Simulator UDID; never a physical device')
args = parser.parse_args()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator,
    'com.tonyredondo.Sonora', 'data'], env=env, text=True).strip())
root = container / 'Documents' / 'Sonora Home QA'
if root.exists() and not (root / '.sonora-demo').exists():
    raise SystemExit('Refusing to overwrite an unmarked folder: ' + str(root))
root.mkdir(parents=True, exist_ok=True)
(root / '.sonora-demo').write_text('Synthetic source-management fixtures. No user music.\n')
for letter, path in [('A', 'tema-a.flac'), ('B', 'En directo/tema-b.flac')]:
    output = root / ('Fuente ' + letter + ' QA') / path
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
        'sine=frequency=440:sample_rate=44100:duration=30', '-c:a', 'flac',
        '-metadata', 'title=Tema fuente ' + letter + ' QA', '-metadata', 'artist=Artista fuentes QA',
        '-metadata', 'album=Álbum fuente ' + letter + ' QA', str(output)], check=True)
print(root)
