const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

function compile(name) {
  return ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/demo', name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017 }
  }).outputText;
}

async function main() {
  const policy = { exports: {} };
  vm.runInNewContext(compile('CaptureFeedbackPolicy'), policy);
  const { CaptureFeedbackGate, CAPTURE_FEEDBACK_DURATION_MS } = policy.exports;
  const frame = (id, now, changes = {}) => ({
    state: 'capturing', authorized: true, privateScene: false,
    frames: Number(id) || 1, frameId: String(id), capturedAt: now, ...changes
  });
  const gate = new CaptureFeedbackGate();
  assert.equal(gate.inspect(frame(1, 10000), false, 10000), '');
  assert.equal(gate.inspect(frame(1, 10000), true, 10000), '', 'do not replay disabled frame');
  for (const change of [{ authorized: false }, { privateScene: true },
    { state: 'waiting_consent' }, { state: 'denied' }, { state: 'error' }, { frames: 0 }]) {
    gate.reset();
    assert.equal(gate.inspect(frame(1, 10000, change), true, 10000), '');
  }
  gate.reset();
  assert.equal(gate.inspect(frame(1, 10000), true, 14000), '', 'stale frame');
  assert.equal(gate.inspect(frame(2, 15000), true, 14000), '', 'future frame');
  assert.match(gate.inspect(frame(3, 15000), true, 15000), /第 3 帧/);
  assert.equal(gate.inspect(frame(3, 15000), true, 18000), '', 'duplicate frame');
  assert.equal(gate.inspect(frame(4, 16000), true, 16000), '', 'do not queue rapid frames');
  assert.match(gate.inspect(frame(5, 17000), true, 17000), /第 5 帧/);
  gate.reset('old');
  assert.equal(gate.inspect(frame('old', 17000), true, 17000), '', 'enable baseline');

  let now = 100000;
  let status = frame('', 0, { state: 'waiting_consent', authorized: false, frames: 0 });
  let counter = 0;
  let permissionDenied = false;
  let publishFailure = false;
  let pendingPublish;
  const intervals = new Map(), timeouts = new Map(), storage = new Map();
  const toasts = [], notifications = [], cancellations = [];
  let permissionRequests = 0;
  const notification = {
    SlotType: { OTHER_TYPES: 0xFFFF },
    ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
    requestEnableNotification: async () => {
      ++permissionRequests;
      if (permissionDenied) throw new Error('permission denied');
    },
    addSlot: async () => {},
    publish: async request => {
      notifications.push(request);
      if (pendingPublish) await pendingPublish;
      if (publishFailure) throw new Error('publish failed');
    },
    cancel: async (id, label) => { cancellations.push([id, label]); }
  };
  const context = {
    exports: {}, Date: class extends Date { static now() { return now; } },
    console: { info() {} },
    AppStorage: { SetOrCreate(key, value) { storage.set(key, value); } },
    setInterval(fn, ms) { const id = ++counter; intervals.set(id, { fn, ms }); return id; },
    clearInterval(id) { intervals.delete(id); },
    setTimeout(fn, ms) { const id = ++counter; timeouts.set(id, { fn, at: now + ms }); return id; },
    clearTimeout(id) { timeouts.delete(id); },
    require(name) {
      if (name === '@ohos.promptAction') return { default: { showToast: v => toasts.push(v) } };
      if (name === '@ohos.notificationManager' || name === '@ohos.notification') return { default: notification };
      if (name === './PhoneScreen') return { PhoneScreen: { status: async () => status } };
      if (name === './CaptureFeedbackPolicy') return policy.exports;
      throw new Error('Unexpected import: ' + name);
    }
  };
  vm.runInNewContext(compile('CaptureFeedback'), context);
  const { CaptureFeedback: feedback } = context.exports;
  const flush = () => new Promise(resolve => setImmediate(resolve));
  async function poll() {
    for (const item of [...intervals.values()]) item.fn();
    await flush();
  }
  async function advance(ms) {
    now += ms;
    for (const [id, item] of [...timeouts]) {
      if (item.at <= now) { timeouts.delete(id); item.fn(); }
    }
    await flush();
  }
  feedback.begin();
  assert.equal(intervals.size, 0, 'disabled by default');
  assert.equal(permissionRequests, 0, 'no permission dialog by default');
  await feedback.setEnabled(true);
  assert.equal(permissionRequests, 1);
  assert.equal(intervals.size, 1);
  await poll(); // baseline while awaiting consent
  status = frame(1, now);
  await poll();
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].duration, CAPTURE_FEEDBACK_DURATION_MS);
  await poll();
  assert.equal(toasts.length, 1, 'same frame must not repeat');
  feedback.setForeground(false);
  await advance(2000);
  status = frame(2, now);
  await poll();
  assert.equal(notifications.length, 1, 'background success uses ordinary notification');
  assert.equal(notifications[0].autoDeletedTime, now + CAPTURE_FEEDBACK_DURATION_MS);
  assert.equal(notifications[0].distributedOption.isDistributed, false);
  assert.match(notifications[0].content.normal.text, /第 2 帧/);
  await advance(CAPTURE_FEEDBACK_DURATION_MS);
  assert.equal(cancellations.length, 1, 'temporary notification clears automatically');
  assert.equal(cancellations[0][1], 'capture-debug', 'do not cancel ongoing background task');

  await feedback.setEnabled(false);
  assert.equal(intervals.size, 0);
  await advance(2000);
  status = frame(3, now);
  await feedback.setEnabled(true);
  await poll();
  assert.equal(notifications.length, 1, 'enabling does not replay existing screenshot');
  await advance(2000);
  status = frame(4, now);
  let finishPublish;
  pendingPublish = new Promise(resolve => { finishPublish = resolve; });
  await poll();
  await feedback.stop();
  const cancelledAtStop = cancellations.length;
  finishPublish();
  await flush();
  pendingPublish = undefined;
  assert.ok(cancellations.length > cancelledAtStop, 'late publish must be cancelled after stop');
  assert.equal(intervals.size, 0);
  assert.equal(timeouts.size, 0);

  feedback.begin();
  await poll();
  status = frame(5, now, { state: 'denied', authorized: false });
  await poll();
  assert.equal(intervals.size, 0, 'denial stops feedback monitor');

  permissionDenied = true;
  await feedback.setEnabled(false);
  await feedback.setEnabled(true);
  feedback.setForeground(true);
  feedback.begin();
  await poll();
  await advance(2000);
  status = frame(6, now);
  await poll();
  assert.match(toasts[toasts.length - 1].message, /第 6 帧/, 'denied notification leaves foreground feedback usable');
  const sent = notifications.length;
  feedback.setForeground(false);
  await advance(2000);
  status = frame(7, now);
  await poll();
  assert.equal(notifications.length, sent, 'no unauthorized background publish');
  assert.match(storage.get('captureFeedbackStatus'), /未就绪/);

  permissionDenied = false;
  await feedback.setEnabled(true);
  await poll();
  await advance(2000);
  publishFailure = true;
  status = frame(8, now);
  await poll();
  assert.match(storage.get('captureFeedbackStatus'), /通知发送失败/);
  publishFailure = false;
  feedback.setForeground(true);
  await feedback.test();
  assert.match(toasts[toasts.length - 1].message, /测试（未截图）/);
  assert.match(notifications[notifications.length - 1].content.normal.title, /测试/);
  await advance(2000);
  const beforeSimulation = toasts.length;
  await feedback.showSimulatedFrame();
  assert.equal(toasts.length, beforeSimulation + 1);
  assert.match(toasts[toasts.length - 1].message, /模拟截图/);
  await feedback.showSimulatedFrame();
  assert.equal(toasts.length, beforeSimulation + 1, 'simulation feedback must be rate limited');
  feedback.setForeground(false);
  await advance(2000);
  await feedback.showSimulatedFrame();
  assert.match(notifications[notifications.length - 1].content.normal.text, /模拟截图/);
  await feedback.stop();
  await feedback.setEnabled(false);
  const beforeDisabled = notifications.length;
  await advance(2000);
  await feedback.showSimulatedFrame();
  assert.equal(notifications.length, beforeDisabled);
  console.log('PASS: real-frame gate, consent/privacy/age/dedupe/rate limits, foreground toast, background notification expiry, off/stop/late-publish cleanup, permission and publish failures, explicit test marker');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
