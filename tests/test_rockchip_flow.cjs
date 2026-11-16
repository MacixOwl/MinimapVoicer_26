const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');
const { spawn } = require('node:child_process');
const ts = require('typescript');

const root = path.resolve(__dirname, '..');

function request(url, options = {}) {
  let active;
  const promise = new Promise((resolve, reject) => {
    active = http.request(url, { method: options.method || 'GET', headers: options.header }, response => {
      const chunks = [];
      response.on('data', data => chunks.push(data));
      response.on('end', () => resolve({ responseCode: response.statusCode,
        result: Buffer.concat(chunks).toString('utf8') }));
    });
    active.on('error', reject);
    active.setTimeout(5000, () => active.destroy(new Error('HTTP timeout')));
    active.end(options.extraData);
  });
  return { promise, destroy: () => active.destroy() };
}

function startBackend() {
  const child = spawn(process.env.PYTHON || 'python',
    ['-u', path.join(root, 'backend/rockchip_mock.py'), '--port', '0'], { cwd: root });
  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error('Mock backend startup timed out')); }, 10000);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('exit', status => { clearTimeout(timer); reject(new Error('Mock backend exited: ' + status)); });
    child.stderr.on('data', () => {});
    child.stdout.on('data', data => {
      output += data;
      const match = output.match(/rockchip_mock_url=(http:\/\/127\.0\.0\.1:\d+)/);
      if (match) { clearTimeout(timer); resolve({ child, origin: match[1] }); }
    });
  });
}

async function main() {
  const backend = await startBackend();
  const nativeStarts = [];
  const spoken = [];
  const forwards = [];
  let failure = '';
  let played = 0;
  let released = 0;
  let preparation = Promise.resolve();
  let synthesisFails = false;
  const proxy = http.createServer((incoming, outgoing) => {
    const chunks = [];
    incoming.on('data', data => chunks.push(data));
    incoming.on('end', async () => {
      try {
        assert.equal(incoming.url, '/v1/chat/completions');
        const body = Buffer.concat(chunks).toString('utf8');
        const payload = JSON.parse(body);
        assert.equal(payload.extra_body.routing.mode, 'peer_preferred');
        forwards.push(payload);
        if (failure === 'network') {
          outgoing.writeHead(503).end('{}');
          return;
        }
        const response = await request(backend.origin + '/peer/v1/chat/completions', {
          method: 'POST', header: { 'Content-Type': 'application/json' }, extraData: body
        }).promise;
        outgoing.writeHead(response.responseCode, { 'Content-Type': 'application/json' });
        outgoing.end(failure === 'text' ? JSON.stringify({ choices: [
          { message: { content: 'unexpected backend response' } }] }) : response.result);
      } catch (error) { outgoing.writeHead(500).end(JSON.stringify({ error: error.message })); }
    });
  });
  try {
    await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
    const localOrigin = 'http://127.0.0.1:' + proxy.address().port;
    const context = { filesDir: '/test-files', cacheDir: '/test-cache', abilityInfo: {}, resourceManager: {
      getRawFileContent: async name => new Uint8Array(fs.readFileSync(
        path.join(root, 'entry/src/main/resources/rawfile', name)))
    } };
    const open = new Set();
    const mocks = {
      '@ohos.app.ability.common': {},
      '@ohos.multimedia.audio': { default: {
        getAudioManager: () => ({ getSessionManager: () => ({
          activateAudioSession: async () => {}, deactivateAudioSession: async () => {}
        }) }),
        AudioConcurrencyMode: { CONCURRENCY_MIX_WITH_OTHERS: 1 },
        ContentType: { CONTENT_TYPE_SPEECH: 1 }, StreamUsage: { STREAM_USAGE_VOICE_ASSISTANT: 3 }
      } },
      '@ohos.app.ability.wantAgent': { default: { getWantAgent: async () => ({}),
        OperationType: { START_ABILITY: 0 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 0 } } },
      '@ohos.resourceschedule.backgroundTaskManager': { default: {
        startBackgroundRunning: async () => {}, stopBackgroundRunning: async () => {},
        BackgroundMode: { AUDIO_PLAYBACK: 1, DATA_TRANSFER: 2 }
      } },
      '@ohos.net.http': { default: { RequestMethod: { GET: 'GET', POST: 'POST' },
        HttpDataType: { STRING: 0 }, createHttp: () => {
          let active;
          return { request: (url, options) => { active = request(url, options); return active.promise; },
            destroy: () => active?.destroy() };
        } } },
      '@ohos.util': { default: {
        TextDecoder: class { decodeWithStream(bytes) { return Buffer.from(bytes).toString('utf8'); } },
        Base64Helper: class {
          encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
          decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
        }
      } },
      '@ohos.multimedia.image': { default: {
        createImageSource: () => ({ getImageInfo: async () => ({ size: { width: 64, height: 64 } }),
          release: async () => {} }), createImagePacker: () => ({ release: async () => {} })
      } },
      '@ohos.file.fs': { default: {
        OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
        openSync: () => { const file = { fd: open.size + 1 }; open.add(file.fd); return file; },
        writeSync: (descriptor, bytes) => bytes.byteLength,
        closeSync: file => { assert.ok(open.delete(file.fd)); }, unlinkSync: () => {}
      } },
      '@ohos.multimedia.media': { default: { createAVPlayer: async () => {
        const events = {};
        return { on: (name, callback) => { events[name] = callback; },
          set fdSrc(value) { assert.ok(open.has(value.fd)); queueMicrotask(() => events.stateChange('initialized')); },
          prepare: async () => { queueMicrotask(() => events.stateChange('prepared')); },
          play: async () => { played++; queueMicrotask(() => events.stateChange('completed')); },
          release: async () => { released++; } };
      } } },
      'libgamevoice.so': { default: { start: async (directory, manifest, peer) => {
        assert.equal(peer, backend.origin);
        assert.equal(JSON.parse(manifest).models[0].id, 'qwen3.5-0.8b-gguf');
        nativeStarts.push(peer);
        return localOrigin;
      } } }
    };
    const cache = {};
    function load(name) {
      if (cache[name]) return cache[name];
      if (name === 'LocalNeuralSpeech') return { LocalNeuralSpeech: {
        prepare: () => preparation,
        synthesize: async (abilityContext, text) => {
          assert.equal(abilityContext, context);
          if (synthesisFails) throw new Error('TTS failure');
          spoken.push(text);
          return new ArrayBuffer(44);
        }
      } };
      if (name === 'ModelStorage') return { ModelStorage: class { async recover() {} } };
      if (name === 'CaptureFeedback') return { CaptureFeedback: { stop: async () => {} } };
      const filename = path.join(root, 'entry/src/main/ets', name === 'Index' ? 'pages/Index.ets' : 'demo/' + name + '.ets');
      let source = fs.readFileSync(filename, 'utf8');
      if (name === 'Index') source = (source.split('\n  build() {')[0] + '\n}')
        .replace(/^@(Entry|Component)\s*$/gm, '')
        .replace(/@(State|StorageLink)(\([^\n]*?\))?\s*/g, '')
        .replace('struct Index {', 'export class Index {');
      const javascript = ts.transpileModule(source, { compilerOptions: {
        module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
      } }).outputText;
      const sandbox = { exports: {}, getContext: () => context, setTimeout, clearTimeout,
        setInterval, clearInterval, Date, console, require: key => {
          if (key.startsWith('.')) return load(path.basename(key));
          return mocks[key] || {};
        } };
      vm.runInNewContext(javascript, sandbox);
      return cache[name] = sandbox.exports;
    }
    const mode = load('DemoMode');
    assert.equal(mode.ROCKCHIP_MOCK_ONLY, true);
    const page = new (load('Index').Index)();
    page.aboutToAppear();
    page.peerEndpoint = backend.origin;
    assert.equal(page.inference, 'peer');
    await page.mockSample();
    assert.match(page.status, /模拟链路完成/);
    assert.equal(page.lastText, mode.ROCKCHIP_MOCK_REPLY);
    assert.deepEqual(spoken, [mode.ROCKCHIP_MOCK_REPLY]);
    assert.equal(played, 1);
    assert.equal(released, 1);
    assert.equal(open.size, 0);
    assert.equal(forwards.length, 1);
    const health = JSON.parse((await request(backend.origin + '/health').promise).result);
    assert.equal(health.received, 1);
    assert.equal(health.fixed_reply, mode.ROCKCHIP_MOCK_REPLY);

    await page.start();
    try {
      const deadline = Date.now() + 3000;
      while (released < 2 && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
      assert.equal(played, 2, 'the first loop iteration must synthesize and play the peer reply');
      assert.equal(released, 2);
      assert.equal(page.lastText, mode.ROCKCHIP_MOCK_REPLY);
    } finally {
      await page.stop();
    }
    const completed = page.count;

    failure = 'text';
    await page.mockSample();
    assert.match(page.status, /模拟链路失败/);
    failure = 'network';
    await page.mockSample();
    assert.match(page.status, /503/);
    assert.equal(spoken.length, 2, 'invalid responses and network failures must not synthesize');
    assert.equal(played, 2);

    failure = '';
    synthesisFails = true;
    await page.mockSample();
    assert.match(page.status, /TTS failure/);
    assert.equal(page.count, completed, 'failed speech must not report completed playback');
    synthesisFails = false;
    const startsBeforeCancel = nativeStarts.length;
    let finishPreparation;
    preparation = new Promise(resolve => { finishPreparation = resolve; });
    const pending = page.mockSample();
    await page.stop();
    finishPreparation();
    await pending;
    assert.equal(nativeStarts.length, startsBeforeCancel);
    await page.downloadModels();
    await page.localSample();
    await page.openModelStorage();
    assert.equal(nativeStarts.length, startsBeforeCancel);
    await assert.rejects(page.runtime.start(''), /仅支持转发/);
    await assert.rejects(page.runtime.download(() => {}), /关闭视觉模型下载/);
    console.log('PASS: real Python mock HTTP, ETS request/reply, local TTS/playback calls, failure and cancellation; native SmartServe and audio engine mocked');
  } finally {
    await new Promise(resolve => proxy.close(resolve));
    const exited = new Promise(resolve => backend.child.once('exit', resolve));
    backend.child.kill();
    await exited;
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
