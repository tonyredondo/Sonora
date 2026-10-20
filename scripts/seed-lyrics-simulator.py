#!/usr/bin/env python3
"""Seed isolated synthetic lyrics fixtures in one simulator's Sonora container."""
import argparse
import os
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
for number, title in [(1, 'Letra completa QA'), (2, 'Letra sincronizada QA'), (3, 'Sin letra QA'), (4, 'Pulso 120 BPM QA')]:
    source = f'sine=frequency={220 * number}:sample_rate=44100:duration=180'
    if number == 4:
        source = r'aevalsrc=0.12*sin(2*PI*880*t)*(0.04+0.96*lt(mod(t\,0.5)\,0.025)):s=44100:d=180'
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
               source,
               '-ac', '2', '-c:a', 'flac', '-metadata', 'title=' + title,
               '-metadata', 'artist=Sonora Tests', '-metadata', 'album=Letras en portada']
    if number == 1:
        command += ['-metadata', 'lyrics=' + '\n'.join(f'Verso {n:02d} de la prueba de Sonora' for n in range(1, 41))]
    subprocess.run(command + [str(root / f'{number:02d} - {title}.flac')], check=True)
(root / '02 - Letra sincronizada QA.lrc').write_text(
    '\n'.join(f'[00:{n:02d}]Línea sincronizada {n:02d}' for n in range(40)), encoding='utf-8')
icon = Path(__file__).resolve().parents[1] / 'Sonora/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
shutil.copyfile(icon, root / 'cover.png')
print(root)
