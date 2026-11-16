#!/usr/bin/env python3
"""Build native local TTS with pinned official OHOS libraries and small weights."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.12.39"
ARCHIVES = {
    "model": ("tts-models/matcha-icefall-zh-baker.tar.bz2", 75455267,
              "ae70096b19c6e283ea351a26b8a718ce6427c8bde8c1da22eb46a5478d39a69b"),
    "vocoder": ("vocoder-models/vocos-22khz-univ.onnx", 53884024,
                "0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081"),
    "ohos": (f"v{VERSION}/sherpa-onnx-v{VERSION}-ohos-arm64-v8a.tar.bz2", 5582756,
             "554f96468c365e4e15d0270fcd5a31ac38648db713c62faf38fa94e1a79e719b"),
    "host": (f"v{VERSION}/sherpa-onnx-v{VERSION}-linux-x64-shared-lib.tar.bz2", 9038829,
             "1b95e49f889dee65310cab832d6181db619ea3ac77ecd60fe8b301028145781c"),
}
MODEL_FILES = {"model.onnx": "model-steps-3.onnx", "tokens.txt": "tokens.txt",
               "lexicon.txt": "lexicon.txt", "phone.fst": "phone.fst",
               "date.fst": "date.fst", "number.fst": "number.fst"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(cache, key):
    relative, size, sha = ARCHIVES[key]
    archive = cache / relative.split("/")[-1]
    if not archive.is_file() or archive.stat().st_size != size:
        partial = archive.with_suffix(".part")
        with urlopen("https://github.com/k2-fsa/sherpa-onnx/releases/download/" + relative,
                     timeout=60) as source, partial.open("wb") as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)
        partial.replace(archive)
    if archive.stat().st_size != size or digest(archive) != sha:
        raise ValueError(f"Pinned archive checksum mismatch: {archive}")
    if key == "vocoder":
        return archive
    with tarfile.open(archive) as source:
        folder = cache / source.getnames()[0].split("/")[0]
        if not folder.exists():
            source.extractall(cache, filter="data")
    return folder


def symbols(tool, path, undefined=False):
    text = subprocess.check_output([str(tool), "--dyn-syms", "--wide", str(path)], text=True)
    result = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[0].rstrip(":").isdigit() and fields[4] in ("GLOBAL", "WEAK"):
            if (fields[6] == "UND") == undefined and (not undefined or fields[4] == "GLOBAL"):
                result.add(fields[7].split("@")[0])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["host", "ohos"], required=True)
    parser.add_argument("--sdk", type=Path, help="API9 directory containing native/")
    parser.add_argument("--cache", type=Path, default=ROOT / "build/phone-tts")
    args = parser.parse_args()
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    model = fetch(cache, "model")
    vocoder = fetch(cache, "vocoder")
    ohos = fetch(cache, "ohos")
    dependency = ohos if args.target == "ohos" else fetch(cache, "host")
    if args.target == "host":
        shutil.copytree(ohos / "include", dependency / "include", dirs_exist_ok=True)
    raw = ROOT / "entry/src/main/resources/rawfile"
    destination = raw / "local-tts"
    destination.mkdir(exist_ok=True)
    files = []
    sources = {name: model / original for name, original in MODEL_FILES.items()}
    sources["vocoder.onnx"] = vocoder
    for name, source in sources.items():
        shutil.copy2(source, destination / name)
        files.append({"filename": name, "size": source.stat().st_size, "sha256": digest(source)})
    (destination / "new_heteronym.fst").unlink(missing_ok=True)
    manifest = {"id": "matcha-icefall-zh-baker", "runtime": f"sherpa-onnx {VERSION}",
                "speaker": 0, "threads": 2, "speed": 1.08,
                "supported_speeds": [1.0, 1.08, 1.18], "sample_rate": 22050,
                "noise_scale": 1.0, "silence_scale": 1.0,
                "comma_pause_ms": 140, "sentence_pause_ms": 220,
                "model_license": "DataBaker dataset: non-commercial use only; see licenses/Matcha-Baker-NOTICE.txt",
                "files": files,
                "total_bytes": sum(f["size"] for f in files)}
    (raw / "local-tts.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    build = cache / ("adapter-" + args.target)
    options = ["-DCMAKE_BUILD_TYPE=Release", f"-DSHERPA_ROOT={dependency}"]
    if args.target == "host":
        options.append("-DPHONE_TTS_HOST=ON")
    else:
        if not args.sdk or not (args.sdk / "native/build/cmake/ohos.toolchain.cmake").is_file():
            parser.error("--sdk must point to the API9 SDK directory")
        native = args.sdk.resolve() / "native"
        llvm = native / "llvm/bin"
        objects = cache / "api9-tls"
        objects.mkdir(exist_ok=True)
        candidates = sorted((native / "llvm/lib/clang").glob(
            "*/lib/aarch64-linux-ohos/libclang_rt.builtins.a"))
        if not candidates:
            raise RuntimeError("API9 compiler-rt archive is missing")
        subprocess.run([str(llvm / "llvm-ar"), "x", str(candidates[0]), "emutls.c.o"],
                       cwd=objects, check=True)
        renamed = objects / "emutls-private.o"
        subprocess.run([str(llvm / "llvm-objcopy"),
                        "--redefine-sym=__emutls_get_address=GameVoicePrivateEmutls",
                        str(objects / "emutls.c.o"), str(renamed)], check=True)
        options.extend([f"-DCMAKE_TOOLCHAIN_FILE={native}/build/cmake/ohos.toolchain.cmake",
                        "-DOHOS_ARCH=arm64-v8a", "-DOHOS_STL=c++_shared",
                        f"-DTLS_OBJECT={renamed}"])
    subprocess.run(["cmake", "-S", str(ROOT / "native/phone_tts"), "-B", str(build),
                    "-G", "Ninja", *options], check=True)
    subprocess.run(["cmake", "--build", str(build), "-j", "4"], check=True)
    if args.target == "ohos":
        libs = ROOT / "entry/libs/arm64-v8a"
        libs.mkdir(parents=True, exist_ok=True)
        for name, source in [
            ("libphonetts.so", build / "libphonetts.so"),
            ("libsherpa-onnx-c-api.so", dependency / "lib/libsherpa-onnx-c-api.so"),
            ("libonnxruntime.so", dependency / "lib/libonnxruntime.so"),
            ("libc++_shared.so", native / "llvm/lib/aarch64-linux-ohos/c++/libc++_shared.so")
        ]:
            shutil.copy2(source, libs / name)
        packaged = [libs / name for name in ("libphonetts.so", "libsherpa-onnx-c-api.so",
                                             "libonnxruntime.so", "libc++_shared.so")]
        system = native / "sysroot/usr/lib/aarch64-linux-ohos"
        baseline = [system / name for name in ("libc.so", "libace_napi.z.so",
                                              "librawfile.z.so", "libhilog_ndk.z.so")]
        exports = set().union(*(symbols(llvm / "llvm-readelf", p) for p in packaged + baseline))
        for path in packaged:
            missing = symbols(llvm / "llvm-readelf", path, True) - exports
            if missing:
                raise RuntimeError(f"{path.name} cannot resolve against API9: {sorted(missing)}")
        report = {"target": "OpenHarmony API9 arm64-v8a", "phone_tested": False,
                  "api9_dynamic_symbol_closure": "passed",
                  "compiler_tls": "API9 compiler-rt emutls implementation with public forwarding entry",
                  "model": manifest,
                  "libraries": [{"filename": p.name, "bytes": p.stat().st_size,
                                 "sha256": digest(p)} for p in packaged],
                  "archives": ARCHIVES}
        (ROOT / "artifacts/phone-tts-build.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("API9 dynamic symbol closure passed; actual phone loading remains unverified.")
    else:
        print(f"Host verification adapter: {build / 'phone_tts'}")
    print(f"Bundled model resources: {manifest['total_bytes']} bytes")


if __name__ == "__main__":
    main()
