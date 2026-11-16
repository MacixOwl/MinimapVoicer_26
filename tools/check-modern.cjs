const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const ideInput = process.argv[2] || process.env.DEVECO_STUDIO_HOME;
if (!ideInput) throw new Error('Set DEVECO_STUDIO_HOME or pass your DevEco Studio installation directory as the first argument.');
const ide = path.resolve(ideInput);
const json5 = require(path.join(ide, 'tools/hvigor/hvigor-ohos-plugin/node_modules/json5'));
const sdkRoot = path.join(ide, 'sdk/default');
const nativeRoot = path.join(sdkRoot, 'openharmony/native');
const executableSuffix = process.platform === 'win32' ? '.exe' : '';
const reader = path.join(nativeRoot, 'llvm/bin/llvm-readelf' + executableSuffix);
const packaged = path.join(root, 'entry/libs/arm64-v8a');
const system = path.join(nativeRoot, 'sysroot/usr/lib/aarch64-linux-ohos');
const options = { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, windowsHide: true };

function inspectNative(libraries) {
  const exported = new Set();
  const required = new Map();
  const pending = [...libraries];
  const inspected = new Set();
  while (pending.length) {
    const name = pending.shift();
    if (inspected.has(name)) continue;
    inspected.add(name);
    const bundled = path.join(packaged, name);
    const file = fs.existsSync(bundled) ? bundled : path.join(system, name);
    if (!fs.existsSync(file)) throw new Error('Missing native dependency: ' + name);
    const dependencies = execFileSync(reader, ['--needed-libs', file], options);
    for (const match of dependencies.matchAll(/^  (\S+)\r?$/gm)) pending.push(match[1]);
    const symbols = execFileSync(reader, ['--dyn-symbols', '--wide', file], options);
    const imports = [];
    for (const line of symbols.split('\n')) {
      const fields = line.trim().split(/\s+/);
      if (fields.length < 8 || !/^\d+:$/.test(fields[0])) continue;
      const symbol = fields[7].split('@')[0];
      if (fields[6] !== 'UND' && ['GLOBAL', 'WEAK'].includes(fields[4])) exported.add(symbol);
      else if (fields[6] === 'UND' && fields[4] === 'GLOBAL') imports.push(symbol);
    }
    if (libraries.includes(name)) required.set(name, imports);
  }
  const result = [...required].map(([name, imports]) => ({
    name, requiredSymbols: imports.length, missing: imports.filter(symbol => !exported.has(symbol))
  }));
  if (result.some(item => item.missing.length)) throw new Error(JSON.stringify(result, null, 2));
  return result;
}

function check() {
  const metadata = JSON.parse(fs.readFileSync(path.join(sdkRoot, 'sdk-pkg.json'), 'utf8')).data;
  const profile = json5.parse(fs.readFileSync(path.join(root, 'build-profile.json5'), 'utf8'));
  const product = profile.app.products.find(item => item.name === 'default');
  if (product?.runtimeOS !== 'HarmonyOS' || product.compileSdkVersion !== metadata.platformVersion) {
    throw new Error('The default product must use HarmonyOS and the installed SDK platformVersion.');
  }
  const pages = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/base/profile/main_pages.json'), 'utf8'));
  if (JSON.stringify(pages.src) !== '["pages/CloudBattle"]') throw new Error('Only CloudBattle should be registered.');
  const raw = path.join(root, 'entry/src/main/resources/rawfile');
  const manifest = JSON.parse(fs.readFileSync(path.join(raw, 'local-tts.json'), 'utf8'));
  for (const file of manifest.files) {
    const bytes = fs.readFileSync(path.join(raw, 'local-tts', file.filename));
    if (bytes.length !== file.size || crypto.createHash('sha256').update(bytes).digest('hex') !== file.sha256) {
      throw new Error('Bundled TTS resource is incomplete: ' + file.filename);
    }
  }
  const libraries = ['libc++_shared.so', 'libgamevoice.so', 'libphonecapture.so', 'libonnxruntime.so',
    'libphonetts.so', 'libsherpa-onnx-c-api.so'];
  const assets = libraries.map(name => {
    const bytes = fs.readFileSync(path.join(packaged, name));
    if (bytes.readUInt32LE(0) !== 0x464c457f || bytes[4] !== 2 || bytes[5] !== 1 || bytes.readUInt16LE(18) !== 183) {
      throw new Error('Expected an arm64 ELF library: ' + name);
    }
    return { name, bytes: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
  });
  const native = inspectNative(libraries);
  const captureLibraries = ['libnative_avscreen_capture.so', 'libnative_media_core.so', 'libnative_buffer.so'];
  const captureSymbols = captureLibraries.map(name => execFileSync(reader,
    ['--dyn-symbols', '--wide', path.join(system, name)], options)).join('\n');
  const adapter = fs.readFileSync(path.join(root, 'native/screen_capture.cpp'), 'utf8');
  const dynamicApis = [...adapter.matchAll(/Load\(\w+, "([^"]+)"/g)].map(match => match[1]);
  for (const symbol of dynamicApis) {
    if (!new RegExp('\\b' + symbol + '\\b').test(captureSymbols)) throw new Error('Missing capture API: ' + symbol);
  }
  execFileSync(path.join(nativeRoot, 'llvm/bin/clang++' + executableSuffix), [
    '--target=aarch64-linux-ohos', '--sysroot=' + path.join(nativeRoot, 'sysroot'),
    '-std=c++17', '-fsyntax-only', path.join(root, 'tests/capture_abi.cpp')
  ], options);
  const report = {
    checkedAt: new Date().toISOString(), ide: JSON.parse(fs.readFileSync(path.join(ide, 'product-info.json'), 'utf8')).version,
    sdk: metadata, product: { name: product.name, compileSdkVersion: product.compileSdkVersion,
      compatibleSdkVersion: product.compatibleSdkVersion, targetSdkVersion: product.targetSdkVersion, runtimeOS: product.runtimeOS },
    ttsFiles: manifest.files.length, assets, native, capture: { dynamicApis, abiLayoutPassed: true },
    deviceTested: false, cloudCredentialsUsed: false
  };
  const directory = path.join(root, 'artifacts');
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'compatibility.modern.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(`PASS: ${metadata.displayName}; ${manifest.files.length} TTS hashes; ${libraries.length} arm64 libraries; native symbols; capture ABI and ${dynamicApis.length} public APIs.`);
}

try { check(); }
catch (error) { console.error(error.message); process.exitCode = 1; }
