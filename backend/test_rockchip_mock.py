import base64
import copy
import json
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from rockchip_mock import FIXED_REPLY, MODEL_ID, RockchipMockServer


class RockchipMockTest(unittest.TestCase):
    def setUp(self):
        self.server = RockchipMockServer(("127.0.0.1", 0))
        self.origin = "http://127.0.0.1:" + str(self.server.server_port)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.shutdown)
        sample = Path(__file__).resolve().parents[1] / "entry/src/main/resources/rawfile/sample.png"
        self.request = {
            "model": MODEL_ID, "stream": False,
            "extra_body": {"routing": {"mode": "peer_preferred"}},
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": "test"},
                {"type": "image_url", "image_url": {
                    "url": "data:image/png;base64," + base64.b64encode(sample.read_bytes()).decode("ascii")}}
            ]}]
        }

    def send(self, body, endpoint="/peer/v1/chat/completions"):
        request = Request(self.origin + endpoint, json.dumps(body).encode("utf-8"),
                          {"Content-Type": "application/json"})
        return urlopen(request, timeout=3)

    def test_peer_request_returns_only_fixed_text(self):
        with self.send(self.request) as response:
            reply = json.load(response)
            self.assertEqual(response.headers["X-Demo-Backend"], "rockchip-mock")
        self.assertEqual(reply["choices"][0]["message"]["content"], FIXED_REPLY)
        self.assertEqual(reply["model"], MODEL_ID)
        self.assertTrue(reply["mock"])
        self.assertNotIn("audio_base64", reply)
        with urlopen(self.origin + "/health", timeout=3) as response:
            self.assertEqual(json.load(response)["received"], 1)

    def test_public_chat_alias_uses_the_same_protocol(self):
        with self.send(self.request, "/v1/chat/completions") as response:
            self.assertEqual(json.load(response)["choices"][0]["message"]["content"], FIXED_REPLY)

    def test_invalid_requests_never_increment_received(self):
        variants = [None, [], {}, {**self.request, "stream": True},
                    {**self.request, "model": "wrong-model"},
                    {**self.request, "messages": []},
                    {**self.request, "messages": [{"role": "user", "content": "no image"}]}]
        damaged = copy.deepcopy(self.request)
        damaged["messages"][0]["content"][1]["image_url"]["url"] = "data:image/png;base64,%%%"
        variants.append(damaged)
        for body in variants:
            with self.subTest(body=body):
                with self.assertRaises(HTTPError) as caught:
                    self.send(body)
                self.assertEqual(caught.exception.code, 400)
        self.assertEqual(self.server.received, 0)

    def test_unknown_endpoint_and_oversized_body(self):
        with self.assertRaises(HTTPError) as caught:
            self.send(self.request, "/analyze")
        self.assertEqual(caught.exception.code, 404)
        request = Request(self.origin + "/peer/v1/chat/completions", b"{}",
                          {"Content-Length": str(13 * 1024 * 1024)})
        with self.assertRaises(HTTPError) as caught:
            urlopen(request, timeout=3)
        self.assertEqual(caught.exception.code, 413)


if __name__ == "__main__":
    unittest.main()
