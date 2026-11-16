#!/usr/bin/env python3
"""Inspect the actual source ZIP against an API9 SDK. Never certify a phone.

Run on the development Linux host with Python 3.12+, Node/TypeScript and SDK9.
Exit 0 means the package checks completed, not that HMOS4.2 screen capture works.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def elf_symbols(tool, path):
    result = subprocess.check_output([str(tool), "--dyn-syms", "--wide", str(path)], text=True)
    exports, required = set(), set()
    for line in result.splitlines():
        fields = line.split()
        if len(fields) < 8 or not fields[0].rstrip(":").isdigit():
            continue
        name = fields[7].split("@")[0]
        if fields[6] == "UND":
            if fields[4] == "GLOBAL":
                required.add(name)
        elif fields[4] in ("GLOBAL", "WEAK"):
            exports.add(name)
    return exports, required


def inspect(args, work):
    report = {
        "checked_at": datetime.now().astimezone().isoformat(),
        "archive": {"filename": args.archive.name, "bytes": args.archive.stat().st_size,
                    "sha256": digest(args.archive.read_bytes())},
        "target": "Huawei Mate60Pro, HarmonyOS4.2, 12GB RAM",
        "phone_connected_or_tested": False,
        "all_interfaces_guaranteed_on_hmos42": False,
        "full_game_flow_certified": False,
        "conclusion": "NOT CERTIFIED: HarmonyOS SDK target build is unverified; capture requires API10/11/12 with no HMOS4.2 guarantee.",
        "scope": "ZIP CRC/assets, SDK declarations and ELF symbol dependencies; no OS/runtime emulation",
    }
    with zipfile.ZipFile(args.archive) as source:
        bad = source.testzip()
        if bad:
            raise ValueError(f"ZIP CRC failed: {bad}")
        for name in source.namelist():
            relative = PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Unsafe ZIP path")
        roots = {PurePosixPath(n).parts[0] for n in source.namelist() if n}
        if len(roots) != 1:
            raise ValueError("Expected one project directory in ZIP")
        source.extractall(work)
    project = work / roots.pop()
    target = json.loads((project / "entry/build-profile.json5").read_text())["targets"][0]
    if target.get("runtimeOS") != "HarmonyOS":
        raise ValueError("Default target must explicitly select HarmonyOS, not implicit OpenHarmony")
    report["harmonyos_build_target"] = {
        "default_runtime_os": target["runtimeOS"], "configuration_corrected": True,
        "commercial_harmonyos_sdk_build_verified": False,
        "local_environment_blocker": "HarmonyOS SDK path hwsdk.dir / HOS_SDK_HOME is unavailable",
        "public_sdk_reference_build_is_not_a_harmonyos_build": True}
    api_result = subprocess.check_output([
        "node", str(project / "tools/audit_api9.cjs"), str(args.sdk), str(project)
    ], text=True)
    report["arkts_api9"] = json.loads(api_result)
    report["arkts_api9"]["sdk_contract_is_not_huawei_firmware_certification"] = True
    raw = project / "entry/src/main/resources/rawfile"
    manifest = json.loads((raw / "local-tts.json").read_text())
    for item in manifest["files"]:
        data = (raw / "local-tts" / item["filename"]).read_bytes()
        if len(data) != item["size"] or digest(data) != item["sha256"]:
            raise ValueError(f"TTS asset mismatch: {item['filename']}")
    if (raw / "local-tts/rule.far").exists():
        raise ValueError("Unused large rule.far should not be packaged")
    report["bundled_tts_assets"] = {
        "passed": True, "files": len(manifest["files"]),
        "total_bytes": manifest["total_bytes"], "model": manifest["id"]}
    model = json.loads((raw / "models.json").read_text())["models"][0]
    report["visual_model"] = {
        "id": model["id"], "weights_bundled": False,
        "download_bytes": sum(f["size"] for f in model["files"]),
        "fixed_revision_url": model["base_url"],
        "checksum_validation": "model manifest SHA256; checked when loading by SmartServe"}
    native = args.sdk / "native"
    readelf = native / "llvm/bin/llvm-readelf"
    system = native / "sysroot/usr/lib/aarch64-linux-ohos"
    libs = sorted((project / "entry/libs/arm64-v8a").glob("*.so"))
    if len(libs) != 5:
        raise ValueError("Expected all five ARM64 native libraries")
    packages = {p.name: p for p in libs}
    definitions, requirements, rows, system_files = set(), {}, [], {}
    for library in libs:
        data = library.read_bytes()
        if data[:6] != b"\x7fELF\x02\x01" or int.from_bytes(data[18:20], "little") != 183:
            raise ValueError(f"Expected ELF64 little-endian AArch64: {library.name}")
        dynamic = subprocess.check_output([str(readelf), "-d", str(library)], text=True)
        search_paths = re.findall(r"\((?:RPATH|RUNPATH)\).*?\[([^\]]*)\]", dynamic)
        if any(part != "$ORIGIN" for value in search_paths for part in value.split(":")):
            raise ValueError(f"Unexpected runtime search path: {library.name}: {search_paths}")
        needed = re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic)
        for name in needed:
            if name not in packages:
                path = system / name
                if not path.is_file():
                    raise ValueError(f"Dependency unavailable in API9 baseline: {name}")
                system_files[name] = path
        exported, undefined = elf_symbols(readelf, library)
        definitions |= exported
        requirements[library.name] = undefined
        rows.append({"filename": library.name, "bytes": len(data), "sha256": digest(data),
                     "machine": "AArch64", "needed": needed, "runtime_search_paths": search_paths})
    for library in system_files.values():
        definitions |= elf_symbols(readelf, library)[0]
    for name, symbols in requirements.items():
        missing = symbols - definitions
        if missing:
            raise ValueError(f"Unresolved strong API9 symbols in {name}: {sorted(missing)}")
    report["native_api9"] = {
        "passed": True, "libraries": rows, "system_baseline": sorted(system_files),
        "sdk_symbol_resolution_is_not_phone_loading_or_instruction_validation": True}
    evidence = json.loads((project / "tools/capture-api-evidence.json").read_text())
    used = set(re.findall(r'Load\([^\n]*"(OH_[^"]+)"',
                         (project / "native/screen_capture.cpp").read_text()))
    known = {item["symbol"]: item for item in evidence["required_symbols"]}
    if used != set(known):
        raise ValueError("Capture interface inventory is stale")
    report["screen_capture"] = {
        "dynamic_runtime_probe": True, "required_api_ceiling": max(known[n]["since"] for n in used),
        "symbols_above_api9": [known[n] for n in sorted(used) if known[n]["since"] > 9],
        "not_an_api9_only_flow": True, "hmos42_supported": None,
        "official_hmos42_support_confirmation_found": False,
        "result": "BLOCKER for claiming guaranteed HMOS4.2 full-flow support",
        "missing_apis_refuse_capture": True}
    interval_source = (project / "entry/src/main/ets/demo/CaptureInterval.ets").read_text()
    intervals = {}
    for key in ("DEFAULT", "MIN", "MAX"):
        match = re.search(rf"{key}_CAPTURE_INTERVAL_SECONDS:\s*number\s*=\s*(\d+)", interval_source)
        if not match:
            raise ValueError("Missing capture interval settings")
        intervals[key.lower() + "_ms"] = int(match.group(1)) * 1000
    report["screen_capture"]["user_interval"] = {
        **intervals, "unit_in_ui": "integer seconds",
        "shared_by_home_and_capture_page": True, "requires_stop_then_start": True,
        "persisted_across_process_restarts": False}
    feedback_policy = (project / "entry/src/main/ets/demo/CaptureFeedbackPolicy.ets").read_text()
    feedback_timings = {}
    for name in ("DURATION", "MIN_GAP", "MAX_AGE"):
        match = re.search(rf"CAPTURE_FEEDBACK_{name}_MS:\s*number\s*=\s*(\d+)", feedback_policy)
        if not match:
            raise ValueError("Missing capture feedback policy")
        feedback_timings[name.lower() + "_ms"] = int(match.group(1))
    report["capture_feedback"] = {
        "default_enabled": False, "requires_successful_new_authorized_frame": True,
        "foreground": "API9 promptAction.showToast",
        "background": "API9 ordinary local notification with expiry and cancellation",
        "notification_permission_requested_only_when_user_enables": True,
        "requires_system_float_window_permission": False,
        "test_message_explicitly_says_no_screenshot": True,
        "timings": feedback_timings,
        "phone_toast_notification_banner_and_background_timer_verified": False}
    pages = json.loads((project / "entry/src/main/resources/base/profile/main_pages.json").read_text())
    if "pages/Models" not in pages["src"]:
        raise ValueError("Model management page missing")
    for filename in ("ModelStorage.ets", "ModelBackup.ets"):
        if not (project / "entry/src/main/ets/demo" / filename).is_file():
            raise ValueError("Model backup implementation missing")
    report["model_storage"] = {
        "private_vision_directory": "filesDir/models/qwen3.5-0.8b-q4",
        "normal_uninstall_keeps_private_models": False,
        "external_backup_format": "SGVBK001 / .gvb, streamed in 1MiB chunks",
        "public_files_require_explicit_document_picker_selection": True,
        "file_open_deferred_to_next_user_action_after_picker": True,
        "system_uninstall_interception_or_prompt": False,
        "restore_checks_bundled_manifest_and_sha256_before_replacement": True,
        "storage_logic_report": "model-storage-verification.json",
        "on_phone_document_picker_uninstall_reinstall_verified": False}
    report["cpu_inference"] = {
        "vision_backend": "llama.cpp CPU in libgamevoice.so",
        "speech_backend": "sherpa-onnx / ONNX Runtime CPU, two synthesis threads",
        "requires_rknn_npu_cuda_python_on_phone": False,
        "linux_shared_source_run_report": "phone-tts-verification.json",
        "actual_hmos42_cpu_run_verified": False,
        "12GB_total_ram_does_not_establish_available_process_ram_or_game_performance": True}
    if args.hap:
        with zipfile.ZipFile(args.hap) as hap:
            if hap.testzip():
                raise ValueError("HAP CRC failed")
            for library in libs:
                if hap.read("libs/arm64-v8a/" + library.name) != library.read_bytes():
                    raise ValueError("HAP and ZIP libraries differ")
            for item in manifest["files"]:
                if digest(hap.read("resources/rawfile/local-tts/" + item["filename"])) != item["sha256"]:
                    raise ValueError("HAP and ZIP models differ")
            if hap.read("resources/rawfile/demo_voice.wav") != (raw / "demo_voice.wav").read_bytes():
                raise ValueError("HAP and ZIP samples differ")
        report["hap_payload_matches_zip"] = {
            "passed": True, "filename": args.hap.name,
            "bytes": args.hap.stat().st_size, "sha256": digest(args.hap.read_bytes()),
            "role": "Unsigned OpenHarmony public API9 reference build; not a validated HarmonyOS target build"}
    report["static_package_checks_passed"] = True
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--hap", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/preflight-compatibility.json")
    args = parser.parse_args()
    args.sdk = args.sdk.resolve()
    with tempfile.TemporaryDirectory(prefix="hmos-preflight-") as temp:
        report = inspect(args, Path(temp))
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("Package/API9 static checks passed.")
    print("NOT CERTIFIED for HMOS4.2: HarmonyOS SDK build unverified; API12 capture callbacks remain a blocker.")
    print(args.output)


if __name__ == "__main__":
    main()
