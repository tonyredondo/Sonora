#!/usr/bin/env python3
"""Create marked synthetic deletion fixtures on one explicitly named Simulator."""
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
root = container / 'Documents' / 'Sonora Borrado QA'
if root.exists() and not (root / '.sonora-delete-qa').exists():
    raise SystemExit('Refusing to overwrite an unmarked folder: ' + str(root))
root.mkdir(parents=True, exist_ok=True)
(root / '.sonora-delete-qa').write_text('Synthetic file-deletion fixtures. No user music.\n')
for name in ['Borrado Noche QA', 'Borrado Papel QA', 'Descarga Borrado QA', 'CUE Borrado QA']:
    for path in ['conservar.flac', 'borrar.flac', 'Subcarpeta QA/Profunda/interior.flac']:
        output = root / name / path
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
            'sine=frequency=440:sample_rate=44100:duration=30', '-c:a', 'flac',
            '-metadata', 'title=' + output.stem, '-metadata', 'artist=Borrado QA', str(output)], check=True)
    (root / name / 'leeme.txt').write_text('Synthetic companion file.\n')
(root / 'CUE Borrado QA' / 'album.cue').write_text('''FILE "borrar.flac" WAVE
TRACK 01 AUDIO
TITLE "Primera pista CUE"
INDEX 01 00:00:00
TRACK 02 AUDIO
TITLE "Segunda pista CUE"
INDEX 01 00:15:00
''')
print(root)
