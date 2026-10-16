#!/usr/bin/env python3
"""Create short, copyright-free codec fixtures with the installed ffmpeg."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
fixtures = root/'SonoraTests'/'Fixtures'
fixtures.mkdir(parents=True, exist_ok=True)
for extension, codec in [('wav','pcm_s16le'),('flac','flac'),('mp3','libmp3lame'),('m4a','aac'),('aiff','pcm_s16be'),('alac.m4a','alac')]:
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',
                    'sine=frequency=440:sample_rate=44100:duration=0.25','-ac','2',
                    '-c:a',codec,'-metadata','title=Señal de prueba','-metadata','artist=Sonora Tests',
                    str(fixtures/('fixture.'+extension))],check=True)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y',
                '-i',str(fixtures/'fixture.flac'),
                '-i',str(root/'Sonora'/'Assets.xcassets'/'AppIcon.appiconset'/'AppIcon.png'),
                '-map','0:a','-map','1:v','-c','copy','-disposition:v','attached_pic',
                '-metadata:s:v','title=Front cover','-metadata:s:v','comment=Cover (front)',
                str(fixtures/'fixture-cover.flac')],check=True)
print(fixtures)
