#!/usr/bin/env python3
"""Host logic checks. These do not emulate or validate a Huawei phone's APIs."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", default="/tmp/gamevoice-capture-checks")
args = parser.parse_args()
build = Path(args.build_dir).resolve()
subprocess.run(["cmake", "-S", str(Path(__file__).parent), "-B", str(build)], check=True)
subprocess.run(["cmake", "--build", str(build), "-j", "4"], check=True)
clean = os.environ.copy()
clean.pop("LD_LIBRARY_PATH", None)
subprocess.run([str(build / "capture_check"), "--missing"], env=clean, check=True)
spec = importlib.util.spec_from_file_location("capture_fixture", root / "backend/server.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
with fixture.DemoServer(("127.0.0.1", 0)) as server, tempfile.TemporaryDirectory() as cache:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        env = clean.copy()
        env["LD_LIBRARY_PATH"] = str(build)
        subprocess.run([str(build / "capture_check"), cache,
                        f"http://127.0.0.1:{server.server_port}"], env=env, check=True, timeout=60)
        assert (Path(cache) / "screen-latest.png").is_file()
    finally:
        server.shutdown()
        thread.join()
