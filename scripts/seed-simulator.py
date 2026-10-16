#!/usr/bin/env python3
"""Add synthetic demo audio to Sonora's Documents on one named simulator."""
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
container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.simulator,'com.tonyredondo.Sonora','data'],env=env,text=True).strip())
root = container/'Documents'/'Sonora QA'
marker = root/'.sonora-demo'
if root.exists() and not marker.exists():
    raise SystemExit('Refusing to overwrite an existing unmarked folder: '+str(root))
root.mkdir(parents=True, exist_ok=True)
marker.write_text('Synthetic, regenerable Sonora simulator fixtures. No user music.\n')
tracks = [('01 - Luz de madrugada.flac','flac','Luz de madrugada',220),
          ('02 - Papel y tinta.mp3','libmp3lame','Papel y tinta',330),
          ('En directo/03 - Horizonte.wav','pcm_s16le','Horizonte en directo',440)]
for name, codec, title, frequency in tracks:
    output = root/name
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',
                    f'sine=frequency={frequency}:sample_rate=44100:duration=30','-ac','2','-c:a',codec,
                    '-metadata','title='+title,'-metadata','artist=Sonora Tests',
                    '-metadata','album=Sesiones Sonora',str(output)], check=True)
icon = Path(__file__).resolve().parents[1]/'Sonora'/'Assets.xcassets'/'AppIcon.appiconset'/'AppIcon.png'
shutil.copyfile(icon,root/'cover.png')
shutil.copyfile(icon,root/'En directo'/'cover.png')
(root/'01 - Luz de madrugada.lrc').write_text('[ar:Sonora Tests]\n[00:00]Luz de madrugada\n[00:05]La ciudad despierta\n[00:10]Un nuevo horizonte\n[00:25]Volvemos a empezar\n', encoding='utf-8')
print(root)
