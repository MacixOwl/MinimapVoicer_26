const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/demo/VoicePlayer.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
} }).outputText;
const flush = () => new Promise(resolve => setImmediate(resolve));
const syntheses = [], speechRates = [], timeouts = [], openFiles = new Set(), cachedFiles = new Set();
let synthesize = async () => new ArrayBuffer(64);
let created = 0, released = 0, played = 0, rawReads = 0, timerNumber = 0;
let autoComplete = true, failPlayer = false, pausePlayback = false;
let activeSessions = 0;
let now = Date.now();
let prepareAudio = async () => {};
const taskDate = class extends Date { static now() { return now; } };
const timing = { exports: {}, Date: taskDate };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/demo/CloudTiming.ets'), 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
} }).outputText, timing);
const audio = {
  getAudioManager: () => ({ getSessionManager: () => ({
    activateAudioSession: async strategy => { assert.equal(strategy.concurrencyMode, 1); activeSessions++; },
    deactivateAudioSession: async () => { activeSessions--; }
  }) }),
  AudioConcurrencyMode: { CONCURRENCY_MIX_WITH_OTHERS: 1 },
  ContentType: { CONTENT_TYPE_SPEECH: 1 }, StreamUsage: { STREAM_USAGE_VOICE_ASSISTANT: 3 }
};
const speech = { synthesize: async (context, text, rate) => {
  syntheses.push(text);
  speechRates.push(rate);
  return synthesize(text);
} };
const media = { createAVPlayer: async () => {
  if (failPlayer) throw new Error('player unavailable');
  ++created;
  const listeners = new Map();
  const emit = state => queueMicrotask(() => listeners.get('stateChange')(state));
  const player = {
    on: (event, callback) => listeners.set(event, callback),
    prepare: async () => {
      await prepareAudio();
      assert.equal(player.audioRendererInfo.content, 1);
      assert.equal(player.audioRendererInfo.usage, 3);
      emit('prepared');
    },
    play: async () => {
      assert.ok(activeSessions > 0, 'playback must hold a mixed audio session');
      ++played;
      if (pausePlayback) emit('paused');
      else if (autoComplete) emit('completed');
    },
    release: async () => { ++released; }
  };
  Object.defineProperty(player, 'fdSrc', { set() { emit('initialized'); } });
  return player;
} };
const io = {
  OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
  openSync: filename => { const fd = openFiles.size + 1; openFiles.add(fd); cachedFiles.add(filename); return { fd }; },
  writeSync: (fd, buffer) => buffer.byteLength,
  closeSync: file => openFiles.delete(file.fd),
  unlinkSync: filename => cachedFiles.delete(filename)
};
class Base64Helper {
  encodeToStringSync(data) { return Buffer.from(data).toString('base64'); }
  decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
}
const context = { exports: {}, Uint8Array, Date: taskDate,
  setTimeout: (callback, duration) => { timeouts.push(duration); return ++timerNumber; },
  clearTimeout() {},
  require(name) {
    const modules = {
      '@ohos.multimedia.media': { default: media },
      '@ohos.multimedia.audio': { default: audio },
      '@ohos.file.fs': { default: io },
      '@ohos.util': { default: { Base64Helper } },
      '@ohos.net.http': { default: { createHttp() { throw new Error('Remote TTS must stay disabled'); } } },
      './LocalNeuralSpeech': { LocalNeuralSpeech: speech },
      './BattleBriefing': { DEFAULT_SPEECH_RATE: 1.08 },
      './CloudTiming': timing.exports,
      './LocalRuntime': { LocalRuntime: class { constructor() { throw new Error('Visual runtime must stay disabled'); } } },
      './BroadcastPolicy': { TEST_BROADCAST: '这是一条测试播报。' },
      './MinimapTracker': { MAP_MAX_AGE_MS: 15000 }
    };
    if (!modules[name]) throw new Error('Unexpected runtime dependency: ' + name);
    return modules[name];
  }
};
vm.runInNewContext(compiled, context);
const { VoicePlayer } = context.exports;
const ability = { cacheDir: '/voice-test', resourceManager: { getRawFileContent: async name => {
  assert.equal(name, 'demo_voice.wav');
  ++rawReads;
  return new Uint8Array([82, 73, 70, 70]);
} } };
async function main() {
  const voice = new VoicePlayer(ability);
  const text = '这是一条模拟回复，请留意小地图。';
  await voice.play({ frame_id: 'mock-1', text });
  assert.deepEqual(syntheses, [text], 'mock reply must use the neural model with the original text');
  assert.deepEqual(speechRates, [1.08]);
  assert.equal(rawReads, 0, 'automatic broadcast must not substitute the bundled WAV');
  await voice.playSample();
  assert.equal(rawReads, 1);
  assert.equal(syntheses.length, 1, 'speaker test should work without neural model initialization');
  assert.equal(played, 2);
  await voice.play({ frame_id: 'fast', text }, '', true, 30000, 1.18);
  assert.equal(speechRates[speechRates.length - 1], 1.18, 'selected speech rate reaches the synthesizer');
  const longText = '测试文字'.repeat(30);
  await voice.play({ frame_id: 'text', text: longText });
  assert.equal(syntheses[syntheses.length - 1], longText);
  assert.ok(timeouts[timeouts.length - 1] > 15000, 'longer text needs sufficient playback time');

  let finishSynthesis;
  synthesize = () => new Promise(resolve => { finishSynthesis = resolve; });
  const before = created;
  const pending = voice.play({ frame_id: 'cancelled', text });
  await flush();
  voice.cancel();
  finishSynthesis(new ArrayBuffer(64));
  await pending;
  assert.equal(created, before, 'cancelling synthesis must prevent late playback');

  synthesize = async () => new ArrayBuffer(64);
  autoComplete = false;
  const playing = voice.play({ frame_id: 'playing', text });
  await flush();
  voice.cancel();
  await playing;
  assert.equal(released, created, 'stopping active audio must release its player');
  failPlayer = true;
  await assert.rejects(voice.play({ frame_id: 'failed', text }), /player unavailable/);
  failPlayer = false;
  autoComplete = true;
  const playedBeforeExpiry = played;
  const synthesesBeforeExpiry = syntheses.length;
  await assert.rejects(voice.play({ frame_id: 'stale-before-synthesis', text, captured_at: now - 8001 },
    '', true, 8000), /有效期/);
  assert.equal(syntheses.length, synthesesBeforeExpiry, 'expired text must not spend local synthesis time');
  synthesize = async () => { now += 8001; return new ArrayBuffer(64); };
  await assert.rejects(voice.play({ frame_id: 'stale-after-synthesis', text, captured_at: now },
    '', true, 8000), /有效期/);
  synthesize = async () => new ArrayBuffer(64);
  prepareAudio = async () => { now += 8001; };
  await assert.rejects(voice.play({ frame_id: 'stale-during-prepare', text, captured_at: now },
    '', true, 8000), /有效期/);
  assert.equal(played, playedBeforeExpiry, 'audio preparation cannot let stale speech escape the final check');
  prepareAudio = async () => { now += 250; };
  await voice.play({ frame_id: 'fresh-at-start', text, captured_at: now - 1000 }, '', true, 8000);
  assert.equal(voice.lastPlaybackAgeMs, 1250, 'latency is measured at audible playback start');
  prepareAudio = async () => {};
  pausePlayback = true;
  await assert.rejects(voice.play({ frame_id: 'interrupted', text }), /其他应用暂停/);
  assert.equal(activeSessions, 0, 'completion, cancellation and failure must release audio sessions');
  assert.equal(openFiles.size, 0);
  assert.equal(cachedFiles.size, 0, 'failed playback must clean temporary files');
  console.log('PASS: local neural synthesis with exact reply text, independent WAV test, long-text playback, cancellation before/during playback and resource cleanup; no visual runtime or remote TTS');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
