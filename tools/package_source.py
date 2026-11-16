#!/usr/bin/env python3
"""Check and export a source tree without local credentials or generated files."""
import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXCLUDE_DIRS = {'.git', '.idea', '.hvigor', '.preview', '.sign', 'material',
                'build', 'artifacts', 'node_modules', 'oh_modules', '__pycache__',
                '.codex', '.agents', '.cache', '.local-private', '.venv', 'venv',
                '.cxx', '.clangd', '.test', '.appanalyzer', '.ssh', '.aws'}
EXCLUDE_SUFFIXES = {'.hap', '.hsp', '.app', '.zip', '.pyc', '.p12', '.pfx', '.p7b',
                    '.cer', '.crt', '.der', '.csr', '.pem', '.key', '.pub', '.p8', '.jks',
                    '.keystore', '.gguf', '.gvb', '.tar', '.gz', '.bz2', '.7z', '.log',
                    '.tmp', '.bak', '.db', '.sqlite', '.sqlite3'}
EXCLUDE_NAMES = {'local.properties', '.npmrc', '.ohpmrc', 'mykey', 'mykey.pub',
                 'Thumbs.db', '.DS_Store', 'PACKAGE_CHECK.json', 'SOURCE_MANIFEST.json',
                 '.netrc', '.gitcredentials', '.pypirc'}
EXCLUDE_PATTERNS = ('id_rsa*', 'id_ed25519*', '*credentials*.json', '*secrets*.json')
TEXT_SUFFIXES = {'.ets', '.ts', '.js', '.cjs', '.json', '.json5', '.md', '.txt',
                 '.py', '.ps1', '.sh', '.cpp', '.h', '.cmake', '.html', '.svg',
                 '.properties', '.xml', '.yaml', '.yml', '.toml', '.ini'}
TEST_CREDENTIALS = {'test-key-never-log', 'saved-test-key', 'first-key', 'latest-key'}
SECRET_PATTERNS = [
    ('private key', re.compile(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----')),
    ('provider API key', re.compile(rb'\bsk-[A-Za-z0-9_-]{24,}\b')),
    ('cloud access key', re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('GitHub token', re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{32,}|github_pat_[A-Za-z0-9_]{50,})\b')),
]
CREDENTIAL_ASSIGNMENT = re.compile(
    r'''(?:api[_-]?key|access[_-]?token|secret[_-]?key|storePassword|keyPassword)\s*["']?\s*[:=]\s*["']([^"'\r\n]+)["']''',
    re.IGNORECASE)
USER_DIRECTORY = re.compile(r'[A-Za-z]:[/\\]+Users[/\\]+(?!Public\b|<|%)[^/\\\s<>]+', re.IGNORECASE)


def excluded(relative):
    return (any(part in EXCLUDE_DIRS for part in relative.parts) or
            relative.name in EXCLUDE_NAMES or relative.suffix.lower() in EXCLUDE_SUFFIXES or
            (relative.name.startswith('.env') and relative.name != '.env.example') or
            any(fnmatch.fnmatch(relative.name, pattern) for pattern in EXCLUDE_PATTERNS))


def source_files(root):
    selected = []
    for directory, subdirectories, filenames in os.walk(str(root), followlinks=False):
        current = Path(directory)
        subdirectories[:] = sorted(name for name in subdirectories
                                  if not excluded((current / name).relative_to(root)))
        for name in filenames:
            source = current / name
            relative = source.relative_to(root)
            if excluded(relative):
                continue
            if source.is_symlink():
                raise ValueError('Source symlinks must be replaced or excluded: ' + relative.as_posix())
            selected.append(source)
    return sorted(selected)


def secret_findings(relative, data):
    findings = []
    for reason, pattern in SECRET_PATTERNS:
        for match in pattern.finditer(data):
            findings.append({'file': relative.as_posix(), 'reason': reason,
                             'line': data[:match.start()].count(b'\n') + 1})
    if relative.suffix.lower() not in TEXT_SUFFIXES and relative.name not in {'.env.example', 'LICENSE'}:
        return findings
    text = data.decode('utf-8', errors='replace')
    for match in USER_DIRECTORY.finditer(text):
        findings.append({'file': relative.as_posix(), 'reason': 'personal Windows user path',
                         'line': text[:match.start()].count('\n') + 1})
    for match in CREDENTIAL_ASSIGNMENT.finditer(text):
        value = match.group(1)
        fixture = relative.parts[0] == 'tests' and value in TEST_CREDENTIALS
        placeholder = (not value or value.startswith(('<', '${', 'YOUR_', 'your_')) or
                       value in {'unknown', 'undefined', 'null'})
        if not fixture and not placeholder:
            findings.append({'file': relative.as_posix(), 'reason': 'literal credential assignment',
                             'line': text[:match.start()].count('\n') + 1})
    return findings


def index_findings(root):
    options = {'cwd': str(root), 'stdout': subprocess.PIPE, 'stderr': subprocess.PIPE}
    result = subprocess.run(['git', 'rev-parse', '--show-prefix'], **options)
    if result.returncode:
        return [], None
    prefix = result.stdout.decode('utf-8').strip()
    result = subprocess.run(['git', 'ls-files', '--cached', '-z', '--', '.'], **options)
    if result.returncode:
        raise ValueError('Cannot inspect the Git index')
    findings = []
    for encoded in result.stdout.split(b'\0'):
        if not encoded:
            continue
        relative = Path(encoded.decode('utf-8'))
        if excluded(relative):
            findings.append({'file': relative.as_posix(), 'reason': 'excluded file is still in Git index'})
            continue
        if relative.suffix.lower() in TEXT_SUFFIXES:
            staged = subprocess.run(['git', 'show', ':' + prefix + relative.as_posix()], **options)
            if staged.returncode:
                raise ValueError('Cannot inspect indexed file: ' + relative.as_posix())
            findings.extend(secret_findings(relative, staged.stdout))
    return findings, prefix == ''


def verify_runtime_assets(root):
    manifest = json.loads((root / 'entry/src/main/resources/rawfile/local-tts.json').read_text(encoding='utf-8-sig'))
    for entry in manifest['files']:
        source = root / 'entry/src/main/resources/rawfile/local-tts' / entry['filename']
        data = source.read_bytes()
        if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('Missing, changed or Git LFS pointer TTS asset: ' + entry['filename'])
    names = ['libc++_shared.so', 'libgamevoice.so', 'libonnxruntime.so',
             'libphonecapture.so', 'libphonetts.so', 'libsherpa-onnx-c-api.so']
    for name in names:
        header = (root / 'entry/libs/arm64-v8a' / name).read_bytes()[:20]
        if header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != 183:
            raise ValueError('Missing or invalid arm64 native library: ' + name)
    return len(manifest['files']), len(names)


def audit(root):
    files = source_files(root)
    findings, independent = index_findings(root)
    for source in files:
        findings.extend(secret_findings(source.relative_to(root), source.read_bytes()))
    if findings:
        raise ValueError(json.dumps({'private_source_findings': findings}, ensure_ascii=False, indent=2))
    speech_count, library_count = verify_runtime_assets(root)
    return files, {'source_files': len(files), 'source_bytes': sum(source.stat().st_size for source in files),
                   'private_source_findings': [], 'git_root_is_project': independent,
                   'tts_assets_verified': speech_count, 'native_libraries_verified': library_count}


def write_archive(root, files, output):
    hashes = {source.relative_to(root).as_posix(): hashlib.sha256(source.read_bytes()).hexdigest()
              for source in files}
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(str(output), 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for source in files:
            archive.write(str(source), root.name + '/' + source.relative_to(root).as_posix())
        archive.writestr(root.name + '/SOURCE_MANIFEST.json', json.dumps(hashes, indent=2) + '\n')
    with zipfile.ZipFile(str(output)) as archive:
        if archive.testzip():
            raise ValueError('ZIP CRC verification failed')
        for relative, expected in hashes.items():
            if hashlib.sha256(archive.read(root.name + '/' + relative)).hexdigest() != expected:
                raise ValueError('ZIP source mismatch: ' + relative)
    return {'filename': output.name, 'bytes': output.stat().st_size,
            'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'entries': len(files) + 1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check source and Git index without making a ZIP')
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    files, summary = audit(root)
    if not args.check:
        version = json.loads((root / 'AppScope/app.json5').read_text(encoding='utf-8-sig'))['app']['versionName']
        output = args.output or root / 'artifacts' / ('hmos-ai-gamer-' + version + '-source.zip')
        summary['archive'] = write_archive(root, files, output.resolve())
        summary['hap_included'] = False
        summary['signing_material_included'] = False
        (output.parent / 'PACKAGE_CHECK.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
