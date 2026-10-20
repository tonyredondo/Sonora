#!/usr/bin/env python3
"""Install the optional, pinned local runtime without changing a proxy service.

Requires uv on PATH. Weights have their own noncommercial licences; see README.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path, help="New or existing app-owned analysis directory")
args = parser.parse_args()
root = args.directory.expanduser().resolve()
marker = root / '.sonora-audio-analysis'
if root.exists() and any(root.iterdir()) and not marker.exists():
    raise SystemExit('Refusing to modify an unmarked analysis directory: ' + str(root))
root.mkdir(parents=True, exist_ok=True)
marker.write_text('Sonora local music analysis runtime.\n')
if not (root / '.venv/bin/python').exists():
    subprocess.run(["uv", "venv", "--python", "3.14", str(root / ".venv")], check=True)
subprocess.run(["uv", "pip", "install", "--python", str(root / ".venv/bin/python"),
                "essentia-tensorflow==2.1b6.dev1438", "numpy==2.5.4", "pyyaml==6.0.3", "six==1.17.0"], check=True)
models = root / "models"
models.mkdir(exist_ok=True)
for entry in json.loads(Path(__file__).with_name("models.json").read_text()):
    for item in entry["files"].values():
        target = models / item["name"]
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == item["sha256"]:
            continue
        with urllib.request.urlopen(item["url"], timeout=60) as response:
            data = response.read(item["bytes"] + 1)
        if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise SystemExit("Downloaded model failed identity validation: " + item["name"])
        target.write_bytes(data)
print('[audio_character]\nenabled = true\npython = ' + json.dumps(str(root / '.venv/bin/python'))
      + '\nmodels = ' + json.dumps(str(models)))
