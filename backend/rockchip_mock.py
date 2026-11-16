"""Mock Rockchip peer: accept SmartServe chat requests without running inference."""
import argparse
import base64
import binascii
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


MODEL_ID = "qwen3.5-0.8b-gguf"
FIXED_REPLY = "这是瑞芯微模拟后端的测试回复。"
MAX_BODY_BYTES = 12 * 1024 * 1024


class RockchipMockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address):
        self.received = 0
        self.lock = threading.Lock()
        super().__init__(address, RockchipMockHandler)


class RockchipMockHandler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(8)

    def respond(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Demo-Backend", "rockchip-mock")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        route = urlsplit(self.path).path
        if route == "/health":
            with self.server.lock:
                received = self.server.received
            self.respond(200, {"status": "ok", "backend": "rockchip-mock", "mock": True,
                               "received": received, "fixed_reply": FIXED_REPLY})
        elif route == "/v1/models":
            self.respond(200, {"object": "list", "data": [
                {"id": MODEL_ID, "object": "model", "owned_by": "rockchip-mock"}]})
        else:
            self.respond(404, {"error": "unknown endpoint"})

    def do_POST(self):
        if urlsplit(self.path).path not in ("/peer/v1/chat/completions", "/v1/chat/completions"):
            self.respond(404, {"error": "unknown endpoint"})
            return
        try:
            size = int(self.headers.get("Content-Length", ""))
            if not 0 < size <= MAX_BODY_BYTES:
                self.respond(413, {"error": "request exceeds size limit"})
                return
            body = self.rfile.read(size)
            if len(body) != size:
                raise ValueError("incomplete request")
            request = json.loads(body)
            validate_chat(request)
        except (ValueError, TypeError, TimeoutError, binascii.Error) as error:
            self.respond(400, {"error": str(error)})
            return
        with self.server.lock:
            self.server.received += 1
            sequence = self.server.received
        self.log_message("received SmartServe request %d; returning fixed text; inference disabled", sequence)
        self.respond(200, {
            "id": "rockchip-mock-" + str(sequence), "object": "chat.completion",
            "created": int(time.time()), "model": MODEL_ID,
            "mock": True, "backend": "rockchip-mock",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": FIXED_REPLY},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
        })


def validate_chat(request):
    if not isinstance(request, dict) or request.get("model") != MODEL_ID:
        raise ValueError("unsupported model")
    if request.get("stream", False) is not False:
        raise ValueError("mock backend only supports non-streaming requests")
    messages = request.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages must be a non-empty array")
    images = 0
    for message in messages:
        if not isinstance(message, dict) or message.get("role") not in ("system", "user", "assistant"):
            raise ValueError("invalid message")
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            continue
        if not isinstance(content, list) or not content:
            raise ValueError("invalid message content")
        for part in content:
            if not isinstance(part, dict):
                raise ValueError("invalid content part")
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                continue
            image = part.get("image_url")
            if part.get("type") != "image_url" or not isinstance(image, dict):
                raise ValueError("unsupported content part")
            url = image.get("url")
            if not isinstance(url, str) or "," not in url:
                raise ValueError("image must use a base64 data URL")
            header, encoded = url.split(",", 1)
            if header not in ("data:image/png;base64", "data:image/jpeg;base64"):
                raise ValueError("unsupported image type")
            pixels = base64.b64decode(encoded, validate=True)
            signature = b"\x89PNG\r\n\x1a\n" if header.startswith("data:image/png") else b"\xff\xd8\xff"
            if not pixels.startswith(signature):
                raise ValueError("invalid image signature")
            images += 1
    if images != 1:
        raise ValueError("provide exactly one image")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8081)
    args = parser.parse_args()
    with RockchipMockServer((args.host, args.port)) as server:
        print("rockchip_mock_url=http://{}:{}".format(args.host, server.server_port), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
