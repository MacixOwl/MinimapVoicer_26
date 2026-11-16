const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const timers = new Map();
let nextTimer = 0;
const screenCalls = [];
let screenState = { supported: false, state: 'unsupported', error: '' };
let screenFrame;
const screen = {
  status: async () => screenState,
  start: async (...args) => { screenCalls.push(['start', ...args]); },
  stop: async () => { screenCalls.push(['stop']); },
  read: async after => screenFrame && screenFrame.id !== after ? screenFrame : undefined
};
function load(name) {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/demo', name + '.ets'), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
  } }).outputText;
  const context = {
    exports: {}, console: { info() {} }, Uint8Array,
    setInterval: callback => { const timer = ++nextTimer; timers.set(timer, callback); return timer; },
    clearInterval: timer => timers.delete(timer),
    require(name) {
      if (name === './PhoneScreen') return { PhoneScreen: screen };
      throw new Error('Unexpected runtime dependency: ' + name);
    }
  };
  vm.runInNewContext(code, context);
  return context.exports;
}
const { MockBroadcast, MockSmartServe, MOCK_REPLY_TEXT } = load('MockBroadcast');
const { SessionCapture } = load('SessionCapture');
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
const frame = id => ({ id: String(id), bytes: new Uint8Array([137, 80, 78, 71]),
  mime: 'image/png', simulated: true });
async function tick() {
  for (const callback of [...timers.values()]) callback();
  await flush();
}

async function main() {
  const service = new MockSmartServe();
  const first = await service.send(frame(1));
  const second = await service.send(frame(2));
  assert.equal(first.text, MOCK_REPLY_TEXT);
  assert.equal(second.text, MOCK_REPLY_TEXT);
  assert.equal(first.frame_id, '1');
  assert.equal(second.frame_id, '2');
  assert.equal(first.audio_base64, undefined, 'reply must go through real local synthesis');
  await assert.rejects(service.send({ ...frame(1), bytes: new Uint8Array() }), /有效画面/);

  let captures = 0;
  let spoken = 0;
  let voiceDone = deferred();
  const replies = [], speech = [], errors = [];
  let cancelCount = 0;
  const hooks = {
    capture: async () => frame(++captures),
    captured: async () => {},
    speak: async reply => { speech.push(reply); await voiceDone.promise; },
    cancelSpeech: () => { ++cancelCount; voiceDone.resolve(); },
    onReply: reply => replies.push(reply),
    onSpoken: () => { ++spoken; },
    onError: message => errors.push(message)
  };
  const session = new MockBroadcast(hooks);
  for (const invalid of [0, 500, 1001.5, 300001, NaN]) {
    assert.throws(() => session.start(invalid), /间隔/);
  }
  session.start(1000);
  await flush();
  assert.equal(captures, 1, 'first frame must not wait for a whole interval');
  assert.equal(speech[0].text, MOCK_REPLY_TEXT);
  await tick();
  await tick();
  assert.equal(captures, 1, 'busy speech must not queue more captures or voices');
  voiceDone.resolve();
  await flush();
  assert.equal(spoken, 1);
  voiceDone = deferred();
  await tick();
  assert.equal(captures, 2);
  await session.stop();
  assert.equal(timers.size, 0);
  assert.equal(spoken, 1, 'stopped speech must not count as completed');
  await tick();
  assert.equal(captures, 2);
  assert.ok(cancelCount > 0);

  const late = deferred();
  const lateSession = new MockBroadcast(hooks, { send: async () => late.promise });
  voiceDone = deferred();
  lateSession.start(1000);
  await flush();
  const before = replies.length;
  const stopping = lateSession.stop();
  assert.throws(() => lateSession.start(1000), /上一轮/);
  late.resolve({ frame_id: 'late', text: MOCK_REPLY_TEXT });
  await stopping;
  assert.equal(replies.length, before, 'late response must not be displayed or spoken');
  voiceDone = deferred();
  lateSession.start(1000);
  await flush();
  assert.equal(replies.length, before + 1, 'clean restart must process new responses');
  await lateSession.stop();

  const captureDone = deferred();
  const beforeCapture = speech.length;
  const delayedCapture = new MockBroadcast({ ...hooks, capture: async () => captureDone.promise });
  delayedCapture.start(1000);
  await flush();
  const captureStopping = delayedCapture.stop();
  captureDone.resolve(frame('cancelled'));
  await captureStopping;
  assert.equal(speech.length, beforeCapture, 'late capture must not reach the mock sender');

  const failed = new MockBroadcast({ ...hooks, speak: async () => { throw new Error('audio failed'); } });
  failed.start(1000);
  await flush();
  assert.match(errors[0], /audio failed/);
  assert.equal(timers.size, 0, 'a failed loop must not repeat indefinitely');
  await failed.stop();

  const context = { resourceManager: { getRawFileContent: async () => frame(1).bytes } };
  const capture = new SessionCapture(context);
  const label = await capture.start(3000);
  assert.match(label, /模拟截图/);
  const sample = await capture.read();
  assert.equal(sample.simulated, true);
  assert.notEqual((await capture.read()).id, sample.id);
  assert.equal(screenCalls.length, 0, 'unsupported device must not start restricted capture');
  await capture.stop();
  await assert.rejects(capture.read(), /先启动/);

  screenState = { supported: true, state: 'waiting_consent', error: '' };
  await capture.start(3000);
  assert.equal(screenCalls[0][0], 'start');
  assert.equal(screenCalls[0][2], '', 'mock mode must not configure screenshot uploads');
  assert.equal(screenCalls[0][3], 3000);
  assert.equal(await capture.read(), undefined, 'authorization wait must not manufacture a screenshot');
  screenState.state = 'capturing';
  screenFrame = { id: 'real', bytes: new Uint8Array([1, 2]).buffer, capturedAt: Date.now() };
  assert.equal((await capture.read()).simulated, false);
  assert.equal(await capture.read(), undefined, 'same native frame must not repeat');
  screenState.state = 'denied';
  await assert.rejects(capture.read(), /取消或停止/);
  await capture.stop();
  assert.equal(screenCalls[1][0], 'stop');
  assert.equal(timers.size, 0);
  console.log('PASS: offline fixed replies, real synthesis handoff, no overlap, cancellation, late replies/captures, restart, error cleanup, labelled fallback, consent and native capture routing');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
