#!/usr/bin/env python3
"""Send screenshots from an explicitly authorized USB debugging session."""

import argparse
import base64
import json
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="http://127.0.0.1:8765")
    parser.add_argument("--adb", default="adb", help="path to adb or executable on PATH")
    parser.add_argument("--serial", help="adb serial if multiple devices are connected")
    parser.add_argument("--interval", type=float, default=10.0)
    parser.add_argument("--once", action="store_true", help="check capture and upload once, then exit")
    args = parser.parse_args()
    if not 1 <= args.interval <= 60:
        parser.error("--interval must be between 1 and 60 seconds")
    command = [args.adb]
    if args.serial:
        command.extend(["-s", args.serial])
    command.extend(["exec-out", "screencap", "-p"])
    sequence = 0
    try:
        while True:
            started = time.monotonic()
            try:
                image = subprocess.run(command, check=True, capture_output=True, timeout=8).stdout
                if not image.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise ValueError("ADB did not return a PNG; check the USB connection and device authorization")
                sequence += 1
                payload = {
                    "frame_id": f"usb-{time.time_ns()}-{sequence}",
                    "source": "usb",
                    "mime": "image/png",
                    "image_base64": base64.b64encode(image).decode("ascii"),
                }
                request = Request(
                    args.server.rstrip("/") + "/analyze",
                    data=json.dumps(payload).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                )
                with urlopen(request, timeout=8) as response:
                    reply = json.load(response)
                print(f'{reply["frame_id"]}: {len(image)} bytes -> {reply["text"]}', flush=True)
                if args.once:
                    return 0
            except (OSError, ValueError, KeyError, URLError, subprocess.SubprocessError) as error:
                detail = getattr(error, "stderr", None)
                if detail:
                    print(detail.decode("utf-8", "replace").strip(), file=sys.stderr)
                print(f"capture failed: {error}", file=sys.stderr, flush=True)
                if args.once:
                    return 1
            time.sleep(max(0, args.interval - (time.monotonic() - started)))
    except KeyboardInterrupt:
        print("\nUSB capture stopped.")


if __name__ == "__main__":
    raise SystemExit(main())
