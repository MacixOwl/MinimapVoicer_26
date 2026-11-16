#!/usr/bin/env python3
"""Measure the actual Linux VLM/TTS processes; never extrapolate phone performance."""
import argparse
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import platform
import re
import signal
import socket
import subprocess
import threading
import time
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]


def post(origin, route, body):
    request = Request(origin + route, data=json.dumps(body).encode(),
                      headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=180) as response:
        return json.load(response)


class Process:
    def __init__(self, command, port, log):
        # Reject an occupied port rather than accidentally measuring another service.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
        self.log = open(log, "w")
        self.proc = subprocess.Popen(command, stdout=self.log, stderr=self.log)
        self.samples = []
        self.done = threading.Event()
        self.started = time.monotonic()
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()
        for _ in range(1800):
            if self.proc.poll() is not None:
                self.stop()
                raise RuntimeError(f"Process exited; inspect {log}")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    self.ready_seconds = time.monotonic() - self.started
                    break
            except OSError:
                self.done.wait(0.1)
        else:
            self.stop()
            raise RuntimeError(f"Process startup timeout; inspect {log}")

    def counters(self):
        try:
            status = Path(f"/proc/{self.proc.pid}/status").read_text()
            rss = int(re.search(r"VmRSS:\s+(\d+)", status)[1]) * 1024
            hwm = int(re.search(r"VmHWM:\s+(\d+)", status)[1]) * 1024
            stat = Path(f"/proc/{self.proc.pid}/stat").read_text().rsplit(")", 1)[1].split()
            cpu = (int(stat[11]) + int(stat[12])) / os.sysconf("SC_CLK_TCK")
            return {"rss_bytes": rss, "hwm_bytes": hwm, "cpu_seconds": cpu}
        except (OSError, TypeError, ValueError):
            return None

    def sample(self):
        while not self.done.is_set():
            value = self.counters()
            if value:
                self.samples.append(value)
            self.done.wait(0.05)

    def measure(self, run):
        before = self.counters()
        start = time.monotonic()
        result = run()
        elapsed = time.monotonic() - start
        after = self.counters()
        cpu = after["cpu_seconds"] - before["cpu_seconds"]
        return result, {"wall_seconds": round(elapsed, 3), "cpu_seconds": round(cpu, 3),
                        "average_cpu_core_equivalents": round(cpu / elapsed, 2),
                        "rss_after_bytes": after["rss_bytes"]}

    def stop(self):
        last = self.counters()
        if last:
            self.samples.append(last)
        self.done.set()
        self.thread.join()
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.log.close()
        return {"peak_rss_bytes": max((x["hwm_bytes"] for x in self.samples), default=0),
                "startup_seconds": round(getattr(self, "ready_seconds", 0), 3),
                "process_exited": self.proc.poll() is not None}


def prompt(name):
    source = (ROOT / "entry/src/main/ets/demo/GamePrompt.ets").read_text()
    body = re.search(r"export const " + name + r": string =([\s\S]*?);\s*(?:\n|$)", source)[1]
    return "".join(re.findall(r"'([^'\n]*)'", body))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vlm-executable", required=True, type=Path)
    parser.add_argument("--vlm-files-dir", required=True, type=Path)
    parser.add_argument("--tts-python", required=True, type=Path)
    parser.add_argument("--tts-model-dir", required=True, type=Path)
    parser.add_argument("--minimap-image", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/linux-resource-profile.json")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {"tested_at": datetime.now().astimezone().isoformat(),
              "platform": platform.platform(), "machine": platform.machine(),
              "cpu_logical_count": os.cpu_count(),
              "affinity_logical_count": len(os.sched_getaffinity(0)),
              "is_phone_measurement": False,
              "scope": "Linux process RSS/CPU. Synthetic images; no game accuracy validation.",
              "vlm": {}, "tts": {}}
    vlm = Process([str(args.vlm_executable.resolve()), "serve", str(args.vlm_files_dir.resolve()),
                   str(ROOT / "entry/src/main/resources/rawfile/models.json"), "", "18780", "18781"],
                  18780, args.output.with_suffix(".vlm.log"))
    try:
        for label, image, system in [
            ("single_frame", ROOT / "entry/src/main/resources/rawfile/sample.png", "GAME_SYSTEM_PROMPT"),
            ("minimap_observation", args.minimap_image, "MINIMAP_SYSTEM_PROMPT")
        ]:
            data = image.read_bytes()
            mime = "image/png" if data.startswith(b"\x89PNG") else "image/jpeg"
            body = {"model": "qwen3.5-0.8b-gguf", "stream": False, "max_tokens": 96 if label.startswith("minimap") else 64,
                    "temperature": 0, "enable_thinking": False,
                    "extra_body": {"routing": {"mode": "local_only"}},
                    "messages": [{"role": "system", "content": prompt(system)},
                                 {"role": "user", "content": [
                                     {"type": "text", "text": "只报告这张裁剪图的当前观测JSON。" if label.startswith("minimap") else "请根据当前画面给出一句提醒。"},
                                     {"type": "image_url", "image_url": {"url": "data:" + mime + ";base64," + base64.b64encode(data).decode()}}
                                 ]}]}
            response, metrics = vlm.measure(lambda: post("http://127.0.0.1:18780", "/v1/chat/completions", body))
            report["vlm"][label] = {**metrics, "image_bytes": len(data),
                                    "fixture_filename": image.name, "response": response}
    finally:
        report["vlm"].update(vlm.stop())
    tts = Process([str(args.tts_python.absolute()), str(ROOT / "backend/server.py"),
                   "--port", "18765", "--tts-model-dir", str(args.tts_model_dir.resolve())],
                  18765, args.output.with_suffix(".tts.log"))
    try:
        for index, text in enumerate(["这是一条测试播报。", "小地图右下敌方标记聚集，注意。"]):
            response, metrics = tts.measure(lambda: post("http://127.0.0.1:18765", "/tts",
                                                       {"frame_id": f"profile-{index}", "text": text}))
            report["tts"][f"case_{index}"] = {**metrics, "text": text,
                                            "audio_bytes": len(base64.b64decode(response["audio_base64"]))}
    finally:
        report["tts"].update(tts.stop())
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
