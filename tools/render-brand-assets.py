"""Render the SVG brand master into launcher and startup PNG resources."""
import argparse
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", type=Path, default=Path(
        r"C:\Program Files\Google\Chrome\Application\chrome.exe"))
    args = parser.parse_args()
    cache = ROOT / "tools/.cache/brand-render"
    cache.mkdir(parents=True, exist_ok=True)
    artifacts = ROOT / "artifacts"
    artifacts.mkdir(exist_ok=True)
    source = ROOT / "design/brand/tactic-icon.svg"

    def screenshot(document, output, width, height):
        command = [str(args.browser), "--headless=new", "--disable-gpu", "--no-first-run",
                   "--no-default-browser-check", "--disable-background-networking", "--hide-scrollbars",
                   "--force-device-scale-factor=1", "--default-background-color=00000000",
                   "--allow-file-access-from-files", "--user-data-dir=" + str(cache / "browser-profile"),
                   "--window-size=" + str(width) + "," + str(height), "--screenshot=" + str(output),
                   document.resolve().as_uri()]
        result = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace", timeout=45)
        if result.returncode or not output.is_file():
            raise RuntimeError("Browser asset rendering failed: " + result.stderr[-1500:])

    namespace = {"svg": "http://www.w3.org/2000/svg"}
    for variant in ["launcher", "startup"]:
        tree = ET.parse(source)
        element = tree.getroot()
        element.set("width", "1024")
        element.set("height", "1024")
        if variant == "startup":
            element.remove(element.find("svg:rect", namespace))
            mark = element.find("svg:g", namespace)
            mark.set("fill", "#171918")
            mark.set("stroke", "#171918")
        document = cache / (variant + ".svg")
        tree.write(document, encoding="utf-8", xml_declaration=True)
        output = cache / (variant + ".png")
        screenshot(document, output, 1024, 1024)
        with Image.open(output) as original:
            if original.size != (1024, 1024):
                raise RuntimeError("Unexpected browser raster dimensions")
            raster = original.convert("RGBA").resize((512, 512), Image.LANCZOS)
            targets = [ROOT / "AppScope/resources/base/media/app_icon.png",
                       ROOT / "entry/src/main/resources/base/media/icon.png"] if variant == "launcher" else [
                           ROOT / "entry/src/main/resources/base/media/startIcon.png"]
            for target in targets:
                raster.save(target, optimize=True)
    screenshot(ROOT / "design/brand/preview.html", artifacts / "brand-preview.png", 1120, 840)
    print("Rendered launcher, ability, startup icons and artifacts/brand-preview.png")


if __name__ == "__main__":
    main()
