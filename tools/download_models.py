#!/usr/bin/env python3
"""Download the pinned demo model into FILES_DIR/models and verify SHA256."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from urllib.request import Request, urlopen


def verified(path, spec):
    if not path.is_file() or path.stat().st_size != spec["size"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == spec["checksum"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files_dir", type=Path)
    args = parser.parse_args()
    manifest = Path(__file__).resolve().parents[1] / "entry/src/main/resources/rawfile/models.json"
    model = json.loads(manifest.read_text())["models"][0]
    root = args.files_dir.expanduser().resolve() / "models"
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    destination = root / model["model_path"]
    destination.mkdir(exist_ok=True)
    for spec in model["files"]:
        path = destination / spec["filename"]
        if verified(path, spec):
            print(f"Verified {path.name}", flush=True)
            continue
        temporary = path.with_suffix(path.suffix + ".part")
        url = model["base_url"] + "/" + spec["filename"]
        request = Request(url, headers={"User-Agent": "game-voice-demo/1"})
        print(f"Downloading {path.name} ({spec['size'] / 1048576:.1f} MiB)", flush=True)
        with urlopen(request, timeout=60) as response, temporary.open("wb") as out:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                out.write(block)
        if not verified(temporary, spec):
            raise RuntimeError(f"Size/SHA256 mismatch: {temporary}")
        os.replace(temporary, path)
        print(f"Verified {path.name}", flush=True)


if __name__ == "__main__":
    main()
