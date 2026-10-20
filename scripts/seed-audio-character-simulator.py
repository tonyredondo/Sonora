#!/usr/bin/env python3
"""Seed marked, regenerable player-layout fixtures and offline style results.

Optional artwork is a local UI reference, never uploaded. These labels are UI
fixtures; actual model inference is verified separately against supplied music.
"""
import argparse
import hashlib
import struct
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator')
parser.add_argument('--cover', type=Path)
args = parser.parse_args()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.simulator,'com.tonyredondo.Sonora','data'],env=env,text=True).strip())
root = container/'Documents'/'Sonora Tags QA'
marker = root/'.sonora-tags-qa'
if root.exists() and not marker.exists():
    raise SystemExit('Refusing to overwrite unmarked folder: '+str(root))
root.mkdir(parents=True, exist_ok=True); marker.write_text('Regenerable synthetic player/tag fixtures.\n')
file = root/'01 - Style layout QA.wav'
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',
                r'aevalsrc=0.15*sin(2*PI*220*t)*(0.3+0.7*lt(mod(t\,0.5)\,0.06)):s=48000:d=180',
                '-ac','2','-c:a','pcm_s24le','-metadata','title=Lost In Your Battle Again',
                '-metadata','artist=Love Division','-metadata','album=November',str(file)],check=True)
cover = args.cover or Path(__file__).resolve().parents[1]/'Sonora/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
shutil.copyfile(cover,root/'cover.png')
cache = container/'Library'/'Application Support'/'MusicTools'/'cache'; cache.mkdir(parents=True,exist_ok=True)
version = 'essentia-discogs-v1'
key = 'character-binding:'+version+':'+file.as_uri()+':'+file.name
info = file.stat()
value = dict(fingerprint=dict(size=info.st_size,modified=info.st_mtime-978307200,inode=info.st_ino), contentID='ui-layout-fixture',
             result=dict(version=version,silent=False,styles=[dict(label='Rock---Alternative Rock',score=0.3),dict(label='Rock---Indie Rock',score=0.2)],
                         moods=dict(happy=0.2,sad=0.8,relaxed=0.9,aggressive=0.1)))
(cache/(hashlib.sha256(key.encode()).hexdigest()+'.json')).write_text(json.dumps(value))
# Seed the PCM result too: Simulator installs may move the app container while
# preserving cached content. The native store must restore this new binding offline.
digest = hashlib.sha256(b'Sonora pcm64-v1\0' + struct.pack('<dIQI',48000.0,2,180*48000,0))
process = subprocess.Popen(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-i',str(file),'-f','f64le','pipe:1'],stdout=subprocess.PIPE)
while block := process.stdout.read(1024*1024):
    digest.update(block)
if process.wait() != 0:
    raise SystemExit('Could not fingerprint synthetic fixture')
content_id = 'pcm64-v1:'+digest.hexdigest()
result_key = 'character:'+version+':'+content_id
(cache/(hashlib.sha256(result_key.encode()).hexdigest()+'.json')).write_text(json.dumps(value['result']))
print(root)
