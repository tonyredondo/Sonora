"""Bounded, offline Essentia worker. stdin is sampled mono 16 kHz PCM16 WAV.

The proxy embeds this source and owns authentication, scheduling and caching.
Each 30-second block is a separately sampled region, never an artificial join.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import wave

os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
os.environ["TF_NUM_INTRAOP_THREADS"] = "4"
os.environ["TF_NUM_INTEROP_THREADS"] = "1"
os.environ["OMP_NUM_THREADS"] = "4"


def main():
    root = Path(sys.argv[1])
    manifest = json.loads(sys.argv[2])
    raw = sys.stdin.buffer.read(2_880_045)
    if not 32_044 <= len(raw) <= 2_880_044:
        raise ValueError("invalid sample size")
    with wave.open(io.BytesIO(raw), "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 16000):
            raise ValueError("invalid PCM format")
        pcm = wav.readframes(wav.getnframes())
    for entry in manifest:
        for item in entry["files"].values():
            if hashlib.sha256((root / item["name"]).read_bytes()).hexdigest() != item["sha256"]:
                raise ValueError("model identity mismatch")
    import numpy as np
    import essentia.standard as es

    audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
    silent = float(np.sqrt(np.mean(audio * audio))) < 1e-5
    result = {"version": "essentia-discogs-v1", "silent": silent,
              "styles": [], "moods": {name: 0.0 for name in ("happy", "sad", "relaxed", "aggressive")}}
    if not silent:
        models, metadata = {}, {}
        for entry in manifest:
            name = entry["id"]
            meta = json.loads((root / entry["files"][".json"]["name"]).read_text())
            metadata[name] = meta
            kwargs = dict(graphFilename=str(root / entry["files"][".pb"]["name"]),
                          input=meta["schema"]["inputs"][0]["name"])
            purpose = "embeddings" if name == "embedding" else "predictions"
            kwargs["output"] = next(o["name"] for o in meta["schema"]["outputs"] if o.get("output_purpose") == purpose)
            models[name] = (es.TensorflowPredictEffnetDiscogs(**kwargs, batchSize=64,
                            lastBatchMode="same", lastPatchMode="repeat") if name == "embedding"
                            else es.TensorflowPredict2D(**kwargs))
        sections = []
        for start in range(0, len(audio), 480_000):
            section_audio = audio[start:start + 480_000]
            # The fixed-batch graph cannot reshape a sub-patch input even when
            # lastPatchMode is repeat. Supply two full patches for short clips.
            if len(section_audio) < 48_000:
                section_audio = np.resize(section_audio, 48_000)
            embedding = np.asarray(models["embedding"](section_audio))
            if embedding.ndim != 2 or embedding.shape[1] != 1280 or not np.isfinite(embedding).all():
                raise ValueError("invalid embedding")
            section = {}
            for name, model in models.items():
                if name == "embedding":
                    continue
                scores = np.asarray(model(embedding)).mean(axis=0)
                if not np.isfinite(scores).all() or np.any(scores < 0) or np.any(scores > 1):
                    raise ValueError("invalid scores")
                section[name] = scores
            sections.append(section)
        genre = np.mean([s["genre"] for s in sections], axis=0)
        result["styles"] = [{"label": metadata["genre"]["classes"][int(i)], "score": float(genre[i])}
                            for i in np.argsort(genre)[::-1][:8]]
        result["moods"] = {name: float(np.mean([s[name][metadata[name]["classes"].index(name)] for s in sections]))
                           for name in result["moods"]}
    print(json.dumps(result, allow_nan=False), flush=True)


if __name__ == "__main__":
    main()
