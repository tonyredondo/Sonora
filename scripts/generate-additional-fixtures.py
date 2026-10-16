#!/usr/bin/env python3
"""Regenerate only Sonora's six synthetic additional-codec test fixtures."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1] / 'SonoraTests' / 'Fixtures'
formats = [('ogg', 'vorbis', ['-strict', '-2']), ('opus', 'libopus', []),
           ('wv', 'wavpack', []), ('tta', 'tta', []),
           ('caf', 'pcm_s16le', []), ('aac', 'aac', [])]
for extension, codec, options in formats:
    destination = root / ('extra.' + extension)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-f', 'lavfi', '-i', 'sine=frequency=523:sample_rate=48000:duration=2',
                    '-ac', '2', '-c:a', codec, *options,
                    '-metadata', 'title=Señal adicional', '-metadata', 'artist=Sonora Tests',
                    '-metadata', 'album=Pruebas de formatos', str(destination)], check=True, timeout=30)
    print(destination.name, destination.stat().st_size)
