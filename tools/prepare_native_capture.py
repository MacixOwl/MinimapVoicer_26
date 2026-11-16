#!/usr/bin/env python3
"""Create a separate project for an authorized API 9 system capture build."""

import argparse
import json
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    if destination.exists() or destination.is_relative_to(source):
        parser.error("destination must be a new directory outside this project")
    ignored = shutil.ignore_patterns(
        ".idea", ".hvigor", ".git", "build", "node_modules", "oh_modules",
        "__pycache__", "artifacts", "local.properties", "*.hap", "*.p12", "*.p7b", "*.cer",
    )
    shutil.copytree(source, destination, ignore=ignored)
    main_dir = destination / "entry/src/main"
    shutil.copyfile(source / "tools/native/FrameSource.ets", main_dir / "ets/demo/FrameSource.ets")
    module_path = main_dir / "module.json5"
    module = json.loads(module_path.read_text(encoding="utf-8"))
    module["module"]["requestPermissions"].append({"name": "ohos.permission.CAPTURE_SCREEN"})
    module_path.write_text(json.dumps(module, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Created {destination}")
    print("Build with a matching Full SDK and an authorized signing profile. This script does not grant permissions.")


if __name__ == "__main__":
    main()
