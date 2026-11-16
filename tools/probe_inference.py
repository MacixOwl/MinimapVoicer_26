#!/usr/bin/env python3
"""Send a real image to SmartServe and optionally synthesize its reply locally."""
import argparse
import base64
import json
import subprocess
import time
from pathlib import Path
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="http://127.0.0.1:18080")
    parser.add_argument("--route", choices=["local_only", "peer_preferred"], default="local_only")
    parser.add_argument("--image", type=Path)
    parser.add_argument("--model", default="qwen3.5-0.8b-gguf")
    parser.add_argument("--speech-executable", type=Path)
    parser.add_argument("--tts-data-parent", type=Path)
    parser.add_argument("--wav", type=Path, default=Path("reply.wav"))
    args = parser.parse_args()
    image = args.image or Path(__file__).resolve().parents[1] / "entry/src/main/resources/rawfile/sample.png"
    data = image.read_bytes()
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        mime = "image/png"
    elif data.startswith(b"\xff\xd8\xff"):
        mime = "image/jpeg"
    else:
        parser.error("--image must be PNG or JPEG")
    if len(data) > 8 * 1024 * 1024:
        parser.error("--image must be at most 8 MiB; resize it first")
    body = {
        "model": args.model, "stream": False, "max_tokens": 64,
        "temperature": 0, "enable_thinking": False,
        "extra_body": {"routing": {"mode": args.route}},
        "messages": [
            {"role": "system", "content":
             "你是游戏画面助手。只根据图片说一句不超过25字的中文提醒。"
             "不猜测英雄或敌方意图。若为示意图或信息不足，只说画面信息不足，注意小地图。"},
            {"role": "user", "content": [
                {"type": "text", "text": "请根据当前画面给出一句提醒。"},
                {"type": "image_url", "image_url": {
                    "url": f"data:{mime};base64," + base64.b64encode(data).decode("ascii")}},
            ]},
        ],
    }
    start = time.monotonic()
    request = Request(args.server.rstrip("/") + "/v1/chat/completions",
                      data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=180) as response:
        result = json.load(response)
        node = response.headers.get("X-SmartServe-Route-Node", "")
    text = result["choices"][0]["message"]["content"]
    if not text.strip():
        raise RuntimeError("Model returned no commentary")
    print(json.dumps({"seconds": round(time.monotonic() - start, 3),
                      "route_node": node, "response": result}, ensure_ascii=False, indent=2))
    if args.speech_executable:
        if not args.tts_data_parent:
            parser.error("--speech-executable needs --tts-data-parent")
        subprocess.run([str(args.speech_executable.resolve()), "speech",
                        str(args.tts_data_parent.resolve()), str(args.wav.resolve()), text], check=True)
        print(f"Speech: {args.wav.resolve()}")


if __name__ == "__main__":
    main()
