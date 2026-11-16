#!/usr/bin/env python3
"""Download pinned CPU TTS weights; optional ASR is for independent verification."""
import argparse
import hashlib
from pathlib import Path
import tarfile
from urllib.request import urlopen


MODELS = [
    ("vits-melo-tts-zh_en", "tts-models", 167006755,
     "e58351ed7149f290a54534538badd4077cdbe6fddc964b24d0bee870415d1514"),
    ("sherpa-onnx-zipformer-ctc-small-zh-int8-2025-07-16", "asr-models", 50536402,
     "6a71c0cc442ba85ac1455ca23e4561e2a1ef18e55269a184a649d54e9cd0524c"),
    ("sherpa-onnx-paraformer-zh-small-2024-03-09", "asr-models", 77920048,
     "da92b3db5218c5be53aad53e57d1b6e63e7fc98a0e054fbdd6dbe18e9c6b1450"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--with-asr", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name, release, size, digest in MODELS if args.with_asr else MODELS[:1]:
        archive = args.output / f"{name}.tar.bz2"
        if not archive.exists() or archive.stat().st_size != size:
            url = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/{release}/{archive.name}"
            partial = archive.with_suffix(".part")
            print(f"Downloading {name}: {size} bytes", flush=True)
            with urlopen(url, timeout=60) as source, partial.open("wb") as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
            partial.replace(archive)
        if archive.stat().st_size != size or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Model archive checksum mismatch: {archive}")
        if not (args.output / name).exists():
            with tarfile.open(archive) as model:
                model.extractall(args.output, filter="data")
        print(f"Verified {name}", flush=True)


if __name__ == "__main__":
    main()
