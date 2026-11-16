import base64
import json
import threading
import time
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server import DEMO_TEXT, FRESH_SECONDS, DemoServer


class DemoHttpTest(unittest.TestCase):
    def setUp(self):
        self.server = DemoServer(("127.0.0.1", 0))
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.shutdown)
        sample = Path(__file__).resolve().parents[1] / "entry/src/main/resources/rawfile/sample.png"
        self.frame = {
            "frame_id": "frame-1",
            "source": "hap",
            "mime": "image/png",
            "image_base64": base64.b64encode(sample.read_bytes()).decode("ascii"),
        }

    def send_frame(self):
        request = Request(
            self.origin + "/analyze",
            data=json.dumps(self.frame).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urlopen(request, timeout=3) as response:
            return json.load(response)

    def send_text(self, text="这是一条测试播报。", frame_id="tts-1"):
        request = Request(self.origin + "/tts", data=json.dumps({
            "text": text, "frame_id": frame_id
        }).encode(), headers={"Content-Type": "application/json"})
        with urlopen(request, timeout=3) as response:
            return json.load(response)

    def test_tts_without_a_model_returns_unavailable(self):
        with self.assertRaises(HTTPError) as caught:
            self.send_text()
        self.assertEqual(caught.exception.code, 503)

    def test_tts_synthesizes_each_supplied_text_and_preserves_identity(self):
        class Speech:
            def synthesize(self, text):
                return b"test audio for " + text.encode()
        self.server.tts = Speech()
        for index, text in enumerate(["这是一条测试播报。", "请留意小地图。"]):
            result = self.send_text(text, f"tts-{index}")
            self.assertEqual(result["text"], text)
            self.assertEqual(result["frame_id"], f"tts-{index}")
            self.assertEqual(base64.b64decode(result["audio_base64"]), b"test audio for " + text.encode())

    def test_tts_rejects_invalid_text_without_synthesis(self):
        class Speech:
            def synthesize(self, text):
                raise AssertionError("Invalid text must not reach synthesis")
        self.server.tts = Speech()
        for text in ["", "中" * 81, None]:
            with self.assertRaises(HTTPError) as caught:
                self.send_text(text)
            self.assertEqual(caught.exception.code, 400)

    def test_native_upload_returns_speakable_demo_reply(self):
        self.assertEqual(self.send_frame(), {"frame_id": "frame-1", "text": DEMO_TEXT})
        with urlopen(self.origin + "/latest", timeout=3) as response:
            self.assertEqual(response.status, 204)

    def test_usb_result_is_read_once_per_frame_and_expires(self):
        self.frame["source"] = "usb"
        self.send_frame()
        with urlopen(self.origin + "/latest", timeout=3) as response:
            self.assertEqual(json.load(response)["text"], DEMO_TEXT)
        with urlopen(self.origin + "/latest?after=frame-1", timeout=3) as response:
            self.assertEqual(response.status, 204)
        with self.server.latest_lock:
            _, reply = self.server.latest_usb
            self.server.latest_usb = (time.monotonic() - FRESH_SECONDS - 1, reply)
        with urlopen(self.origin + "/latest", timeout=3) as response:
            self.assertEqual(response.status, 204)

    def test_invalid_image_does_not_replace_live_frame(self):
        self.frame["source"] = "usb"
        self.send_frame()
        self.frame.update(frame_id="frame-2", image_base64="%%%")
        with self.assertRaises(HTTPError) as caught:
            self.send_frame()
        self.assertEqual(caught.exception.code, 400)
        with urlopen(self.origin + "/latest", timeout=3) as response:
            self.assertEqual(json.load(response)["frame_id"], "frame-1")

    # The actual image returns to the phone and enters its SmartServe router.
    def test_usb_frame_endpoint_preserves_pixels_and_skips_duplicates(self):
        self.frame["source"] = "usb"
        self.send_frame()
        with urlopen(self.origin + "/latest-frame", timeout=3) as response:
            frame = json.load(response)
        self.assertEqual(frame, {k: self.frame[k] for k in ("frame_id", "mime", "image_base64")})
        with urlopen(self.origin + "/latest-frame?after=frame-1", timeout=3) as response:
            self.assertEqual(response.status, 204)
        with self.server.latest_lock:
            _, frame = self.server.latest_usb_frame
            self.server.latest_usb_frame = (time.monotonic() - FRESH_SECONDS - 1, frame)
        with urlopen(self.origin + "/latest-frame", timeout=3) as response:
            self.assertEqual(response.status, 204)


if __name__ == "__main__":
    unittest.main()
