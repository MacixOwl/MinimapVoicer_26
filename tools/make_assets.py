#!/usr/bin/env python3
"""Regenerate the synthetic test frame and the offline Mandarin demo phrase."""

import argparse
import struct
import subprocess
import sys
import zlib
from pathlib import Path


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def sample_png():
    width, height = 240, 136
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rgb = (24, 44, 55)
            if abs(x - 45) <= 2 or abs(y - 30) <= 2 or abs((height - y) * 2 - x) <= 5:
                rgb = (65, 106, 113)
            if any((x - cx) ** 2 + (y - cy) ** 2 <= 20 for cx, cy in [(42, 96), (90, 90), (54, 34)]):
                rgb = (79, 224, 173)
            if any((x - cx) ** 2 + (y - cy) ** 2 <= 20 for cx, cy in [(143, 58), (187, 31), (179, 65)]):
                rgb = (248, 113, 109)
            rows.extend(rgb)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    engine = parser.add_mutually_exclusive_group(required=True)
    engine.add_argument("--tts-model-dir", type=Path, help="local MeloTTS ONNX model directory")
    engine.add_argument("--espeak", help="explicitly use the legacy, unverified eSpeak voice")
    parser.add_argument("--data-parent", help="directory containing espeak-ng-data, if needed")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(project / "backend"))
    from neural_tts import TEST_TEXT

    rawfiles = project / "entry/src/main/resources/rawfile"
    rawfiles.mkdir(parents=True, exist_ok=True)
    (rawfiles / "sample.png").write_bytes(sample_png())
    if args.tts_model_dir:
        from neural_tts import MeloTts
        (rawfiles / "demo_voice.wav").write_bytes(MeloTts(args.tts_model_dir).synthesize(TEST_TEXT))
    else:
        executable = [args.espeak]
        if args.data_parent:
            executable.append(f"--path={args.data_parent}")
        subprocess.run(
            executable + ["-v", "cmn", "-s", "160", "-w", str(rawfiles / "demo_voice.wav"), "--stdin"],
            input=TEST_TEXT.encode("utf-8"),
            check=True,
        )


if __name__ == "__main__":
    main()
