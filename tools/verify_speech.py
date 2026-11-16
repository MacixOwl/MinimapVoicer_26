#!/usr/bin/env python3
"""Generate neural speech and independently transcribe it without hotwords."""
import argparse
import base64
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import sys
import threading
import time
from urllib.request import Request, urlopen
import wave
from zoneinfo import ZoneInfo

import numpy as np
import sherpa_onnx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from neural_tts import MeloTts, TEST_TEXT
from server import DemoServer


def normalize(text):
    return re.sub(r"[\W_]+", "", text, flags=re.UNICODE).lower()


def decode(recognizer, audio):
    with wave.open(io.BytesIO(audio)) as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2:
            raise ValueError("Expected mono PCM16")
        rate = wav.getframerate()
        pcm = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2")
    samples = pcm.astype(np.float32) / 32768
    stream = recognizer.create_stream()
    # No prompt, expected text, or hotwords are supplied to the ASR.
    stream.accept_waveform(rate, samples)
    recognizer.decode_stream(stream)
    return {
        "asr_text": stream.result.text,
        "sample_rate": rate,
        "seconds": round(len(pcm) / rate, 3),
        "peak": int(np.max(np.abs(pcm.astype(np.int32)))),
        "clipped_samples": int(np.count_nonzero(np.abs(pcm.astype(np.int32)) >= 32767)),
        "sha256": hashlib.sha256(audio).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tts-model-dir", required=True, type=Path)
    parser.add_argument("--asr-model-dir", required=True, type=Path)
    parser.add_argument("--cross-asr-model-dir", type=Path, help="optional independent Paraformer model")
    parser.add_argument("--http", action="store_true", help="exercise the actual POST /tts route")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--replace-assets", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    asr = sherpa_onnx.OfflineRecognizer.from_zipformer_ctc(
        model=str(args.asr_model_dir / "model.int8.onnx"),
        tokens=str(args.asr_model_dir / "tokens.txt"),
        num_threads=2, provider="cpu", decoding_method="greedy_search",
    )
    cross = None
    if args.cross_asr_model_dir:
        cross = sherpa_onnx.OfflineRecognizer.from_paraformer(
            paraformer=str(args.cross_asr_model_dir / "model.int8.onnx"),
            tokens=str(args.cross_asr_model_dir / "tokens.txt"),
            num_threads=2, provider="cpu",
        )
    report = {
        "tested_at": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
        "platform": "Linux CPU",
        "runtime": f"sherpa-onnx {sherpa_onnx.__version__}",
        "tts_model": args.tts_model_dir.name,
        "tts_weight_bytes": (args.tts_model_dir / "model.onnx").stat().st_size,
        "tts_weight_sha256": hashlib.sha256((args.tts_model_dir / "model.onnx").read_bytes()).hexdigest(),
        "asr_model": args.asr_model_dir.name,
        "asr_weight_sha256": hashlib.sha256((args.asr_model_dir / "model.int8.onnx").read_bytes()).hexdigest(),
        "asr_has_hotwords_or_expected_text": False,
        "human_listening_verified": False,
        "phone_playback_verified": False,
        "through_actual_http_endpoint": args.http,
        "synthesis": {"speed": 0.9, "noise_scale": 0.0, "noise_scale_w": 0.0,
                      "peak_normalization": 0.85},
        "cases": [],
    }
    if cross:
        report["cross_check_asr_model"] = args.cross_asr_model_dir.name
    old = args.output_dir / "model-reply.wav"
    if old.is_file() and hashlib.sha256(old.read_bytes()).hexdigest() == \
            "94a88559199f8841690c6d12ccf74c3322cc0d7046680ba9c431b3eb0b123d22":
        report["legacy_espeak"] = decode(asr, old.read_bytes())
    engine = MeloTts(args.tts_model_dir)
    server = DemoServer(("127.0.0.1", 0), tts=engine) if args.http else None
    thread = threading.Thread(target=server.serve_forever, daemon=True) if server else None
    if thread:
        thread.start()
    try:
        for filename, text, required in [
            ("test-broadcast.wav", TEST_TEXT, True),
            ("model-reply.wav", "画面信息不足，注意小地图。", True),
            ("test-minimap.wav", "注意小地图。", False),
        ]:
            start = time.perf_counter()
            if server:
                request = Request(f"http://127.0.0.1:{server.server_port}/tts",
                    data=json.dumps({"frame_id": filename, "text": text}).encode(),
                    headers={"Content-Type": "application/json"})
                with urlopen(request, timeout=15) as response:
                    reply = json.load(response)
                if reply["frame_id"] != filename or reply["text"] != text:
                    raise ValueError("HTTP audio response is for a different text")
                audio = base64.b64decode(reply["audio_base64"], validate=True)
            else:
                audio = engine.synthesize(text)
            elapsed = time.perf_counter() - start
            details = decode(asr, audio)
            matches = normalize(text) == normalize(details["asr_text"])
            path = args.output_dir / filename
            path.write_bytes(audio)
            result = {
                "filename": filename, "input_text": text, "required_case": required,
                "synthesis_seconds": round(elapsed, 3),
                **details, "normalized_exact_match": matches,
            }
            if cross:
                result["cross_check_asr_text"] = decode(cross, audio)["asr_text"]
                result["cross_check_exact_match"] = normalize(text) == normalize(result["cross_check_asr_text"])
            report["cases"].append(result)
            print(json.dumps(result, ensure_ascii=False), flush=True)
    finally:
        if server:
            server.shutdown()
            thread.join()
            server.server_close()
    report["all_exact_matches"] = all(case["normalized_exact_match"] for case in report["cases"])
    report["required_cases_exact_match"] = all(
        case["normalized_exact_match"] and case.get("cross_check_exact_match", True)
        for case in report["cases"] if case["required_case"]
    )
    (args.output_dir / "tts-verification.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    )
    if not report["required_cases_exact_match"]:
        raise RuntimeError("A required test sentence failed independent transcription")
    if args.replace_assets:
        raw = ROOT / "entry/src/main/resources/rawfile"
        shutil.copy2(args.output_dir / "test-broadcast.wav", raw / "demo_voice.wav")
        (raw / "demo_voice.txt").write_text(TEST_TEXT + "\n")
    print("PASS: required test sentences match. Check diagnostic cases separately; human listening and phone playback remain unverified.")


if __name__ == "__main__":
    main()
