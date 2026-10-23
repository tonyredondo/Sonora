#!/usr/bin/env python3
"""Create marked synthetic files for Files → Open With → Sonora UI checks."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator', help='Simulator UDID; never a physical device')
args = parser.parse_args()
env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator,
                                         'com.tonyredondo.Sonora', 'data'], env=env, text=True).strip())
root = container / 'Documents' / 'Sonora Open QA'
marker = root / '.sonora-open-audio-demo'
if root.exists() and not marker.exists():
    raise SystemExit('Refusing to overwrite an unmarked folder: ' + str(root))
root.mkdir(parents=True, exist_ok=True)
marker.write_text('Synthetic, regenerable Files Open-In-Place fixtures. No user music.\n')
icon = Path(__file__).resolve().parents[1] / 'Sonora/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
for name, title, codec, container_type in [('First.mp3', 'Desde Archivos', 'libmp3lame', 'mp3'),
                                            ('Second.WAV', 'Otro archivo', 'pcm_s16le', 'wav')]:
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
               'sine=frequency=330:sample_rate=44100:duration=90']
    if container_type == 'mp3':
        command += ['-i', str(icon), '-map', '0:a', '-map', '1:v', '-c:v', 'png', '-disposition:v', 'attached_pic']
    command += ['-ac', '2', '-c:a', codec, '-metadata', 'title=' + title,
                '-metadata', 'artist=Sonora Open QA', '-metadata', 'album=Prueba externa',
                '-metadata', 'lyrics=[00:00]Primera frase\n[00:30]Última frase', '-f', container_type, str(root / name)]
    subprocess.run(command, check=True)
print(root)
