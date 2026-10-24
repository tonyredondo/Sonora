#!/usr/bin/env python3
"""Seed an already-generated PNG for the marked Files QA song, without editing audio.

Install Sonora and run seed-open-audio-simulator.py first. This script makes no
provider requests; image generation is verified separately with the native CLI.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator', help='Simulator UDID, never a physical device')
parser.add_argument('image', type=Path, help='Existing square PNG from the native generation probe')
args = parser.parse_args()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator,
                                         'com.tonyredondo.Sonora', 'data'], env=env, text=True).strip())
audio = container / 'Documents/Sonora Open QA/Second.WAV'
if not (audio.parent / '.sonora-open-audio-demo').is_file() or not audio.is_file():
    raise SystemExit('Missing marked synthetic Files QA fixture')
image = args.image.read_bytes()
if not image.startswith(b'\x89PNG\r\n\x1a\n') or len(image) > 10_000_000:
    raise SystemExit('Expected a bounded PNG')
width, height = struct.unpack('>II', image[16:24])
if not (0 < width == height <= 2048):
    raise SystemExit('Expected a square PNG no larger than2048 pixels')
with tempfile.TemporaryDirectory(prefix='sonora-artwork-fingerprint-') as directory:
    script = Path(directory) / 'fingerprint.swift'
    script.write_text('''import Foundation
let a = try FileManager.default.attributesOfItem(atPath: CommandLine.arguments[1])
let d: [String: Any] = ["size": (a[.size] as! NSNumber).uint64Value,
                      "inode": (a[.systemFileNumber] as! NSNumber).uint64Value,
                      "modified": (a[.modificationDate] as! Date).timeIntervalSinceReferenceDate]
print(String(data: try JSONSerialization.data(withJSONObject: d), encoding: .utf8)!)
''')
    fingerprint = json.loads(subprocess.check_output(['xcrun', 'swift', str(script), str(audio)], env=env, text=True))
owner = 'app:' + str(audio.relative_to(container)) + ':' + audio.name
key = 'generated-artwork-qa-native-photo-v1'
image_dir = container / 'Library/Application Support/Sonora/GeneratedArtwork'
binding_dir = container / 'Library/Application Support/MusicTools/cache'
image_dir.mkdir(parents=True, exist_ok=True)
binding_dir.mkdir(parents=True, exist_ok=True)
image_file = image_dir / (hashlib.sha256(key.encode()).hexdigest() + '.plist')
binding_file = binding_dir / (hashlib.sha256(('generated-artwork-binding-v1:' + owner).encode()).hexdigest() + '.json')
image_file.write_bytes(plistlib.dumps(dict(data=image, status=200, savedAt=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), key=key), fmt=plistlib.FMT_BINARY))
binding_file.write_text(json.dumps(dict(fingerprint=fingerprint, imageKey=key)))
print(json.dumps(dict(owner=owner, audio_sha256=hashlib.sha256(audio.read_bytes()).hexdigest(), image_sha256=hashlib.sha256(image).hexdigest())))
