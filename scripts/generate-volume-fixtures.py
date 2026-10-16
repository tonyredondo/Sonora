#!/usr/bin/env python3
"""Create only the six one-second codec fixtures needed for BS.1770 measurement."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1] / 'SonoraTests' / 'Fixtures'
for extension, codec in [('wav', 'pcm_s16le'), ('flac', 'flac'), ('mp3', 'libmp3lame'),
                         ('m4a', 'aac'), ('aiff', 'pcm_s16be'), ('alac.m4a', 'alac')]:
    path = root / ('volume.' + extension)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                    'sine=frequency=1000:sample_rate=44100:duration=1', '-ac', '2', '-c:a', codec,
                    '-metadata', 'title=Medición de volumen', '-metadata', 'artist=Sonora Tests', str(path)],
                   check=True, timeout=20)
    print(path.name, path.stat().st_size)
