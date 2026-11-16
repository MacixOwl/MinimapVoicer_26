const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

function deferred() {
  let resolve;
  const promise = new Promise(complete => { resolve = complete; });
  return { promise, resolve };
}

function loadIndex(mocks) {
  const source = fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/pages/Index.ets'), 'utf8').split('\n  build() {')[0] + '\n}';
  const javascript = ts.transpileModule(source
    .replace(/^@(Entry|Component)\s*$/gm, '')
    .replace(/@(State|StorageLink)(\([^\n]*?\))?\s*/g, '')
    .replace('struct Index {', 'export class Index {'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017 }
    }).outputText;
  const sandbox = { exports: {}, getContext: () => ({ abilityInfo: {} }),
    clearInterval, setInterval, Date, console,
    require: name => mocks[name] || {} };
  vm.runInNewContext(javascript, sandbox);
  return new sandbox.exports.Index();
}

async function main() {
  const preparation = deferred();
  let starts = 0;
  let backgroundStarts = 0;
  let screenReads = 0;
  const mocks = {
    '../demo/DemoMode': { ROCKCHIP_MOCK_ONLY: false },
    '../demo/DemoApi': { DemoApi: class { cancel() {} resetTemporal() {} } },
    '../demo/LocalNeuralSpeech': { LocalNeuralSpeech: { prepare: () => preparation.promise } },
    '../demo/BroadcastPolicy': { TEST_BROADCAST: 'test' },
    '../demo/CaptureInterval': { parseCaptureIntervalMs: () => 10000 },
    '../demo/CaptureFeedback': { CaptureFeedback: { stop: async () => {} } },
    '@ohos.app.ability.wantAgent': { default: {
      getWantAgent: async () => ({}), OperationType: { START_ABILITY: 0 },
      WantAgentFlags: { UPDATE_PRESENT_FLAG: 0 }
    } },
    '@ohos.resourceschedule.backgroundTaskManager': { default: {
      startBackgroundRunning: async () => { backgroundStarts++; },
      BackgroundMode: { AUDIO_PLAYBACK: 1 }
    } }
  };
  const page = loadIndex(mocks);
  page.runtime = { start: async () => { starts++; return 'http://127.0.0.1:18080'; } };
  const starting = page.start();
  await page.stop();
  preparation.resolve();
  await starting;
  assert.equal(starts, 0, 'leaving the page while preparing TTS must not start inference');
  assert.equal(backgroundStarts, 0);

  const samplePreparation = deferred();
  mocks['../demo/LocalNeuralSpeech'].LocalNeuralSpeech.prepare = () => samplePreparation.promise;
  const samplePage = loadIndex(mocks);
  samplePage.runtime = page.runtime;
  const sampling = samplePage.localSample();
  await samplePage.stop();
  samplePreparation.resolve();
  await sampling;
  assert.equal(starts, 0, 'a cancelled sample must not load the visual model');

  const playback = deferred();
  const previewPage = loadIndex(mocks);
  previewPage.voice = { playSample: () => playback.promise, cancel: () => {} };
  const previewing = previewPage.preview(true);
  await previewPage.stop();
  const stoppedStatus = previewPage.status;
  playback.resolve();
  await previewing;
  assert.equal(previewPage.status, stoppedStatus, 'a cancelled preview must not report success');

  const screenStatus = deferred();
  mocks['../demo/PhoneScreen'] = { PhoneScreen: {
    status: () => screenStatus.promise,
    read: async () => { screenReads++; }
  } };
  const screenPage = loadIndex(mocks);
  screenPage.source = 'screen';
  screenPage.running = true;
  screenPage.runId = 4;
  const polling = screenPage.tick('', 4);
  screenPage.runId = 5;
  screenPage.status = 'new session';
  screenStatus.resolve({ authorized: false, state: 'stopped' });
  await polling;
  assert.equal(screenPage.runId, 5, 'an old poll must not stop a new session');
  assert.equal(screenPage.running, true);
  assert.equal(screenPage.status, 'new session');
  assert.equal(screenReads, 0);
  console.log('Page lifecycle: cancelled startup, sample, preview and stale polling passed');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
