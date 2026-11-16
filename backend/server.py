#!/usr/bin/env python3
"""Tiny HTTP fixture for the native HarmonyOS voice demo."""

import argparse
import base64
import binascii
import json
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


DEMO_TEXT = "这是一条测试播报。"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_BODY_BYTES = (MAX_IMAGE_BYTES + 2) // 3 * 4 + 4096
FRESH_SECONDS = 12


class DemoServer(ThreadingHTTPServer):
    def __init__(self, address, text=DEMO_TEXT, audio=None, tts=None):
        self.reply_fields = {"text": text}
        if audio is not None:
            self.reply_fields["audio_base64"] = base64.b64encode(audio).decode("ascii")
        self.latest_usb = None
        self.latest_usb_frame = None
        self.latest_lock = threading.Lock()
        self.tts = tts
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(8)

    def respond(self, status, payload=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/health":
            self.respond(200, {"status": "ok", "engine": "fake",
                               "tts": "melo-tts-cpu" if self.server.tts else "disabled"})
        elif url.path in ("/latest", "/latest-frame"):
            after = parse_qs(url.query).get("after", [""])[0]
            with self.server.latest_lock:
                latest = self.server.latest_usb_frame if url.path == "/latest-frame" else self.server.latest_usb
            if latest is not None:
                received_at, reply = latest
                if time.monotonic() - received_at <= FRESH_SECONDS and reply["frame_id"] != after:
                    self.respond(200, reply)
                    return
            self.respond(204)
        else:
            self.respond(404, {"error": "unknown endpoint"})

    def do_POST(self):
        if self.path not in ("/analyze", "/tts"):
            self.respond(404, {"error": "unknown endpoint"})
            return
        try:
            size = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.respond(400, {"error": "missing or invalid Content-Length"})
            return
        limit = 4096 if self.path == "/tts" else MAX_BODY_BYTES
        if not 0 < size <= limit:
            self.respond(413, {"error": "request exceeds image size limit"})
            return
        try:
            request = json.loads(self.rfile.read(size))
            if self.path == "/tts":
                self.speak(request)
                return
            frame_id, source, mime, image = parse_frame(request)
        except (ValueError, TypeError, TimeoutError, binascii.Error) as error:
            self.respond(400, {"error": str(error)})
            return
        reply = {"frame_id": frame_id, **self.server.reply_fields}
        if source == "usb":
            with self.server.latest_lock:
                self.server.latest_usb = (time.monotonic(), reply)
                self.server.latest_usb_frame = (time.monotonic(), {
                    "frame_id": frame_id, "mime": mime,
                    "image_base64": request["image_base64"],
                })
        # Report receipt without writing the screenshot to disk.
        self.log_message("received %s frame %s (%s, %d bytes)", source, frame_id, mime, len(image))
        self.respond(200, reply)

    def speak(self, request):
        if self.server.tts is None:
            self.respond(503, {"error": "Neural TTS is not configured; use --tts-model-dir"})
            return
        if not isinstance(request, dict):
            raise ValueError("request must be an object")
        text, frame_id = request.get("text"), request.get("frame_id")
        if not isinstance(text, str) or not text.strip() or len(text) > 80:
            raise ValueError("TTS text must contain 1 to 80 characters")
        if not isinstance(frame_id, str) or not 1 <= len(frame_id) <= 128 or not frame_id.isascii():
            raise ValueError("invalid frame_id")
        try:
            audio = self.server.tts.synthesize(text)
        except RuntimeError as error:
            self.respond(503, {"error": str(error)})
            return
        self.respond(200, {
            "frame_id": frame_id, "text": text,
            "audio_base64": base64.b64encode(audio).decode("ascii"),
        })


def parse_frame(request):
    if not isinstance(request, dict):
        raise ValueError("request must be an object")
    frame_id = request.get("frame_id")
    source = request.get("source")
    mime = request.get("mime")
    encoded = request.get("image_base64")
    if not isinstance(frame_id, str) or not 1 <= len(frame_id) <= 128 or not frame_id.isascii():
        raise ValueError("invalid frame_id")
    if source not in ("hap", "usb"):
        raise ValueError("source must be hap or usb")
    if not isinstance(encoded, str):
        raise ValueError("image_base64 must be a string")
    image = base64.b64decode(encoded, validate=True)
    if not 0 < len(image) <= MAX_IMAGE_BYTES:
        raise ValueError("invalid image size")
    if mime == "image/png" and image.startswith(PNG_SIGNATURE):
        return frame_id, source, mime, image
    if mime == "image/jpeg" and image.startswith(b"\xff\xd8\xff") and image.endswith(b"\xff\xd9"):
        return frame_id, source, mime, image
    raise ValueError("expected a PNG or JPEG image")


def synthesize(text, executable):
    with tempfile.TemporaryDirectory(prefix="game-voice-") as directory:
        output = Path(directory) / "reply.wav"
        subprocess.run(
            [executable, "-v", "cmn", "-s", "160", "-w", str(output), "--stdin"],
            input=text.encode("utf-8"),
            check=True,
            timeout=20,
        )
        audio = output.read_bytes()
        if not audio or len(audio) > 1024 * 1024:
            raise ValueError("unexpected WAV size")
        return audio


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--text", default=DEMO_TEXT)
    parser.add_argument("--espeak", metavar="EXECUTABLE", help="synthesize the reply with a local espeak-ng executable")
    parser.add_argument("--tts-model-dir", type=Path,
                        help="enable dynamic POST /tts with local MeloTTS ONNX weights")
    args = parser.parse_args()
    if not args.text.strip() or len(args.text) > 80:
        parser.error("--text must have 1 to 80 characters")
    try:
        audio = synthesize(args.text, args.espeak) if args.espeak else None
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(f"could not synthesize speech: {error}")
    try:
        if args.tts_model_dir:
            from neural_tts import MeloTts
            tts = MeloTts(args.tts_model_dir)
        else:
            tts = None
    except (ImportError, ValueError, RuntimeError) as error:
        parser.error(f"could not initialize neural TTS: {error}")
    with DemoServer((args.host, args.port), args.text, audio, tts=tts) as server:
        print(f"Game Voice demo listening on http://{args.host}:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
