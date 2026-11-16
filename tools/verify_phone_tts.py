#!/usr/bin/env python3
"""Exercise the shared phone-TTS C++ code on Linux, optionally after real VLM inference.

Requires numpy/sherpa-onnx only for independent ASR. These packages and ASR
weights are verification tools; they are not required or packaged on the phone.
"""
import argparse
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
import wave

import numpy as np
import sherpa_onnx
from profile_linux import Process, post, prompt

ROOT = Path(__file__).resolve().parents[1]


def normalize(text):
    return re.sub(r"[\W_]+", "", text, flags=re.UNICODE).lower()


def inspect(audio, recognizers):
    with wave.open(io.BytesIO(audio)) as wav:
        assert wav.getnchannels() == 1 and wav.getsampwidth() == 2
        rate = wav.getframerate()
        pcm = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2")
    assert 0 < len(pcm) <= rate * 15
    peak = int(np.max(np.abs(pcm.astype(np.int32))))
    assert 0 < peak < 32767
    decoded = {}
    for name, recognizer in recognizers.items():
        stream = recognizer.create_stream()
        stream.accept_waveform(rate, pcm.astype(np.float32) / 32768)
        recognizer.decode_stream(stream)
        decoded[name] = stream.result.text
    return {"sha256": hashlib.sha256(audio).hexdigest(), "bytes": len(audio),
            "sample_rate": rate, "seconds": round(len(pcm) / rate, 3),
            "peak": peak, "asr": decoded}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--asr-model-dir", required=True, type=Path)
    parser.add_argument("--cross-asr-model-dir", required=True, type=Path)
    parser.add_argument("--vlm-executable", type=Path)
    parser.add_argument("--vlm-files-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--replace-assets", action="store_true")
    args = parser.parse_args()
    if bool(args.vlm_executable) != bool(args.vlm_files_dir):
        parser.error("VLM executable and files directory must be supplied together")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    recognizers = {
        "zipformer_ctc": sherpa_onnx.OfflineRecognizer.from_zipformer_ctc(
            model=str(args.asr_model_dir / "model.int8.onnx"),
            tokens=str(args.asr_model_dir / "tokens.txt"), num_threads=2),
        "paraformer": sherpa_onnx.OfflineRecognizer.from_paraformer(
            paraformer=str(args.cross_asr_model_dir / "model.int8.onnx"),
            tokens=str(args.cross_asr_model_dir / "tokens.txt"), num_threads=2),
    }
    report = {"tested_at": datetime.now().astimezone().isoformat(),
              "platform": "Linux CPU; shared phone-TTS speech.cpp",
              "runtime": "sherpa-onnx 1.12.39 C API",
              "model": args.model_dir.name,
              "model_sha256": hashlib.sha256((args.model_dir / "model.onnx").read_bytes()).hexdigest(),
              "phone_tested": False, "human_listening_verified": False,
              "config": {"speaker": 0, "threads": 2, "speed": 1.08,
                         "noise_scale": 1.0, "silence_scale": 1.0,
                         "comma_pause_ms": 140, "sentence_pause_ms": 220,
                         "peak_normalization": 0.9, "max_gain": 4.0},
              "asr_has_hotwords_or_expected_text": False,
              "asr_models": [args.asr_model_dir.name, args.cross_asr_model_dir.name],
              "quality_disagreements_are_recorded_not_hidden": True, "cases": []}

    def synthesize(filename, text):
        output = args.output_dir / filename
        memory = output.with_suffix(".rss.tmp")
        start = time.monotonic()
        result = subprocess.run(
            ["/usr/bin/time", "-f", "%M", "-o", str(memory),
             str(args.adapter.resolve()), str(args.model_dir.resolve()), text, str(output)],
            check=True, capture_output=True, text=True)
        elapsed = time.monotonic() - start
        details = inspect(output.read_bytes(), recognizers)
        case = {"filename": filename, "input_text": text, **details,
                "cold_process_wall_seconds": round(elapsed, 3),
                "adapter_metrics": result.stdout.strip(),
                "linux_tts_process_peak_rss_bytes": int(memory.read_text().strip()) * 1024,
                "normalized_exact_match": {
                    name: normalize(value) == normalize(text) for name, value in details["asr"].items()}}
        memory.unlink()
        report["cases"].append(case)
        print(json.dumps(case, ensure_ascii=False), flush=True)
        return case

    synthesize("test-broadcast.wav", "这是一条测试播报。")
    synthesize("local-tts-minimap.wav", "小地图左上敌方标记增多，注意观察。")
    if args.vlm_executable:
        vlm = Process(
            [str(args.vlm_executable.resolve()), "serve", str(args.vlm_files_dir.resolve()),
             str(ROOT / "entry/src/main/resources/rawfile/models.json"), "", "18780", "18781"],
            18780, args.output_dir / "phone-local-chain.vlm.log")
        try:
            import base64
            data = (ROOT / "entry/src/main/resources/rawfile/sample.png").read_bytes()
            body = {
                "model": "qwen3.5-0.8b-gguf", "stream": False, "max_tokens": 64,
                "temperature": 0, "enable_thinking": False,
                "extra_body": {"routing": {"mode": "local_only"}},
                "messages": [
                    {"role": "system", "content": prompt("GAME_SYSTEM_PROMPT")},
                    {"role": "user", "content": [
                        {"type": "text", "text": "请根据当前画面给出一句提醒。"},
                        {"type": "image_url", "image_url": {
                            "url": "data:image/png;base64," + base64.b64encode(data).decode()}}]}]}
            result, metrics = vlm.measure(lambda: post("http://127.0.0.1:18780", "/v1/chat/completions", body))
            raw_text = result["choices"][0]["message"]["content"]
            # Execute the actual app's policy, not a Python reimplementation.
            node_script = """
const ts = require('typescript'), fs = require('fs');
const moduleObject = {exports:{}};
const source = fs.readFileSync(process.argv[1], 'utf8');
const compiled = ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText;
new Function('exports','module',compiled)(moduleObject.exports,moduleObject);
process.stdout.write(moduleObject.exports.normalizeBroadcast(process.argv[2]));
"""
            normalized = subprocess.run(
                ["node", "-e", node_script,
                 str(ROOT / "entry/src/main/ets/demo/BroadcastPolicy.ets"), raw_text],
                capture_output=True, text=True, check=True).stdout
            assert normalized
            report["local_chain"] = {
                "image": "built-in synthetic sample.png; not an actual game",
                "route": "SmartServe local_only -> Qwen3.5-0.8B -> app BroadcastPolicy -> shared C++ Matcha",
                "response": result, "broadcast_text": normalized, "vlm_request": metrics,
                "tts": synthesize("model-reply.wav", normalized),
                "phone_capture_and_playback_tested": False}
        finally:
            report["vlm_process"] = vlm.stop()
    else:
        synthesize("model-reply.wav", "画面信息不足，注意小地图。")
    report["all_asr_exact_matches"] = all(
        all(case["normalized_exact_match"].values()) for case in report["cases"])
    report["waveform_checks_passed"] = True
    (args.output_dir / "phone-tts-verification.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if args.replace_assets:
        raw = ROOT / "entry/src/main/resources/rawfile"
        shutil.copy2(args.output_dir / "test-broadcast.wav", raw / "demo_voice.wav")
        (raw / "demo_voice.txt").write_text("这是一条测试播报。\n")
    print("Waveforms valid; inspect ASR disagreements and listen on the actual phone.")


if __name__ == "__main__":
    main()
