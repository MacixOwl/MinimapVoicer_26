const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const source = path.join(__dirname, '../entry/src/main/ets/demo/CloudPhoneScreen.ets');
const calls = [];
const frame = { bytes: new ArrayBuffer(4), id: 'native-frame', capturedAt: 1234 };
const screen = { width: 1260, height: 2720 };
const state = { supported: true, requiredApi: 20, canvasRotation: true, followRotation: true };
const native = {
  screenStatus: async () => JSON.stringify(state),
  startScreen: async (...args) => { calls.push(args); return JSON.stringify(state); },
  readScreen: async after => { assert.equal(after, 'previous-frame'); return frame; },
  stopScreen: async () => { calls.push('stop'); return ''; }
};
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(source, 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
} }).outputText, {
  exports: exportsObject,
  require: key => {
    if (key === '@ohos.display') return { default: { getDefaultDisplaySync: () => screen } };
    if (key === 'libphonecapture.so') return { default: native };
    if (key === './CaptureInterval') return { DEFAULT_CAPTURE_INTERVAL_SECONDS: 10 };
    throw new Error('Unexpected runtime dependency: ' + key);
  }
}, { filename: source });

async function main() {
  const { CloudPhoneScreen, cloudCaptureCanvas } = exportsObject;
  const portrait = cloudCaptureCanvas(1260, 2720);
  assert.equal(portrait.height, 1920);
  assert.ok(Math.abs(portrait.width / portrait.height - 1260 / 2720) < 0.002);
  const landscape = cloudCaptureCanvas(2720, 1260);
  assert.equal(landscape.width, portrait.height);
  assert.equal(landscape.height, portrait.width);
  const small = cloudCaptureCanvas(720, 1280);
  assert.equal(small.width, 720);
  assert.equal(small.height, 1280);
  for (const [width, height] of [[0, 720], [1280, NaN], [Infinity, 1280], [1280, 1]]) {
    assert.throws(() => cloudCaptureCanvas(width, height), /屏幕尺寸/);
  }
  assert.equal((await CloudPhoneScreen.status()).requiredApi, 20);
  const started = await CloudPhoneScreen.start({ cacheDir: '/private/cache' }, '', 17000);
  assert.equal(started.canvasRotation, true);
  assert.equal(started.followRotation, true);
  assert.deepEqual(calls[0], ['/private/cache', '', 17000, portrait.width, portrait.height]);
  screen.width = 2720;
  screen.height = 1260;
  await CloudPhoneScreen.start({ cacheDir: '/private/cache' });
  assert.deepEqual(calls[1], ['/private/cache', '', 10000, landscape.width, landscape.height]);
  assert.equal(await CloudPhoneScreen.read('previous-frame'), frame);
  await assert.rejects(CloudPhoneScreen.start({ cacheDir: '/private/cache' }, 'https://unexpected-upload'), /原生截图上传/);
  assert.equal(calls.length, 2);
  await CloudPhoneScreen.stop();
  assert.equal(calls[2], 'stop');
  const entrySource = path.join(__dirname, '../entry/src/main/ets/entryability/EntryAbility.ets');
  let stopped = 0;
  const abilityExports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(entrySource, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
  } }).outputText, {
    exports: abilityExports,
    require: key => {
      if (key === '@ohos.app.ability.UIAbility') return { default: class {} };
      if (key === '../demo/CloudPhoneScreen') return { CloudPhoneScreen: { stop: async () => { stopped++; } } };
      if (key === '../demo/PhoneScreen') return { PhoneScreen: { stop: async () => {} } };
      if (key === '../demo/CaptureFeedback') return { CaptureFeedback: { stop: async () => {} } };
      throw new Error('Unexpected ability dependency: ' + key);
    }
  });
  new abilityExports.default().onDestroy();
  assert.equal(stopped, 1, 'destroying the ability must stop the new native capture');
  console.log('PASS: native cloud capture uses device aspect ratio, even dimensions, resolution cap, rotation status, no native uploader and lifecycle bridge');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
