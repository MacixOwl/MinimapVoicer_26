const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.resolve(__dirname, '..');
const briefing = '左侧出现多名英雄标记，请留意交战。';

function harness() {
  const state = {
    now: Date.now(), calls: [], crops: [], speech: [], played: 0, nativeStarts: [], nativeStops: 0,
    width: 2000, height: 1000, responseCode: 200, content: briefing, frame: undefined,
    status: { supported: true, requiredApi: 12, missing: [], state: 'capturing', authorized: true,
      privateScene: false, error: '' }, prepare: async () => {}, synthesize: async () => {},
    respond: async () => {}, holdPlayback: false, fileSequence: 0, open: new Map(), positions: new Map(),
    selected: new Uint8Array(Buffer.from('FULL_SCREEN_SHOULD_NEVER_BE_UPLOADED')),
    savedSettings: new Map(), flushSettings: async () => {}, backgroundModes: [], backgroundStops: 0,
    notify: async () => {}, audioSessions: 0, rawBlack: false, cropBlack: false,
    visibleRect: [0, 0, 1, 1], releasedImages: 0, decoderOptions: [], paddingCalls: [],
    usage: undefined, destroyedRequests: 0, fireCloudDeadline: undefined, reads: [], packedCrop: 'CROPPED_JPEG'
  };
  const context = { cacheDir: '/cache', abilityInfo: { bundleName: 'com.demo.hmos.aigamer' } };
  const timers = new Map();
  let timerSequence = 100000;
  const cache = {};
  const mocks = {
    '@ohos.app.ability.common': {},
    '@ohos.notificationManager': { default: { requestEnableNotification: () => state.notify() } },
    '@ohos.multimedia.audio': { default: {
      getAudioManager: () => ({ getSessionManager: () => ({
        activateAudioSession: async strategy => {
          assert.equal(strategy.concurrencyMode, 1);
          state.audioSessions++;
        },
        deactivateAudioSession: async () => { state.audioSessions--; }
      }) }),
      AudioConcurrencyMode: { CONCURRENCY_MIX_WITH_OTHERS: 1 },
      ContentType: { CONTENT_TYPE_SPEECH: 1 }, StreamUsage: { STREAM_USAGE_VOICE_ASSISTANT: 3 }
    } },
    '@ohos.data.preferences': { default: { getPreferencesSync: (abilityContext, options) => {
      assert.equal(abilityContext, context);
      assert.equal(options.name, 'cloud_battle_settings');
      const values = new Map(state.savedSettings);
      return {
        getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
        putSync: (key, value) => values.set(key, value),
        flush: async () => {
          const snapshot = new Map(values);
          await state.flushSettings();
          state.savedSettings = snapshot;
        }
      };
    } } },
    '@ohos.app.ability.wantAgent': { default: { getWantAgent: async () => ({}),
      OperationType: { START_ABILITY: 0 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 0 } } },
    '@ohos.resourceschedule.backgroundTaskManager': { default: {
      startBackgroundRunning: async (abilityContext, modes) => { state.backgroundModes = Array.from(modes); },
      stopBackgroundRunning: async () => { state.backgroundStops++; },
      BackgroundMode: { DATA_TRANSFER: 1 }
    } },
    '@ohos.net.http': { default: { RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 0 },
      createHttp: () => ({ destroy() { state.destroyedRequests++; }, request: async (url, options) => {
        state.calls.push({ url, options, body: JSON.parse(options.extraData), at: state.now });
        await state.respond();
        return { responseCode: state.responseCode, result: JSON.stringify({ choices: [
          { finish_reason: 'stop', message: { content: state.content } }], usage: state.usage }) };
      } }) } },
    '@ohos.util': { default: { Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    } } },
    '@ohos.multimedia.image': { default: {
      PixelMapFormat: { RGBA_8888: 3 },
      createImageSource: buffer => {
        assert.deepEqual(Buffer.from(buffer), Buffer.from(state.selected));
        return { getImageInfo: async () => ({ size: { width: state.width, height: state.height }, mimeType: 'image/png' }),
        createPixelMap: async options => {
          state.decoderOptions.push(options);
          let isCrop = Boolean(options.desiredRegion);
          let region = options.desiredRegion || { x: 0, y: 0,
            size: { width: state.width, height: state.height } };
          if (isCrop) state.crops.push(region);
          let width = options.desiredSize?.width || region.size.width;
          let height = options.desiredSize?.height || region.size.height;
          return { get isCrop() { return isCrop; },
            crop: async requested => {
              assert.ok(!isCrop, 'crop must act on the original decoded pixels');
              assert.ok(!options.desiredSize, 'static screenshot must not be resized before cropping');
              isCrop = true;
              region = requested;
              width = region.size.width;
              height = region.size.height;
              state.crops.push(region);
            },
            getImageInfo: async () => ({ size: { width, height } }),
            scale: async scale => { width = Math.round(width * scale); height = Math.round(height * scale); },
            readPixelsToBuffer: async buffer => {
              const bytes = new Uint8Array(buffer);
              const [left, top, rectWidth, rectHeight] = state.visibleRect;
              for (let row = 0; row < height; row++) {
                for (let column = 0; column < width; column++) {
                  const sourceX = (region.x + (column + 0.5) * region.size.width / width) / state.width;
                  const sourceY = (region.y + (row + 0.5) * region.size.height / height) / state.height;
                  const visible = !state.rawBlack && !(isCrop && state.cropBlack) &&
                    sourceX >= left && sourceX < left + rectWidth && sourceY >= top && sourceY < top + rectHeight;
                  const offset = (row * width + column) * 4;
                  bytes[offset] = bytes[offset + 1] = bytes[offset + 2] = visible ? 100 : 0;
                  bytes[offset + 3] = 255;
                }
              }
            },
            release: async () => { state.releasedImages++; }
          };
        }, release: async () => {} };
      },
      createPixelMap: async (buffer, options) => {
        state.paddingCalls.push({ bytes: new Uint8Array(buffer), options });
        assert.equal(options.srcPixelFormat, 3, 'RGBA source channels must not be interpreted as BGRA');
        assert.equal(options.size.width, options.size.height);
        assert.equal(buffer.byteLength, options.size.width * options.size.height * 4);
        return { isCrop: true, release: async () => { state.releasedImages++; } };
      },
      createImagePacker: () => ({ packing: async pixels => new Uint8Array(Buffer.from(
        pixels.isCrop ? state.packedCrop : 'SOURCE_THUMBNAIL_LOCAL_ONLY')).buffer,
        release: async () => {} })
    } },
    '@ohos.file.picker': { default: { PhotoViewMIMETypes: { IMAGE_TYPE: 'image/*' },
      PhotoViewPicker: class { async select() { return { photoUris: ['photo://screenshot'] }; } } } },
    '@ohos.file.fs': { default: {
      OpenMode: { READ_ONLY: 1, CREATE: 2, READ_WRITE: 4, TRUNC: 8 },
      openSync: uri => {
        const file = { fd: ++state.fileSequence };
        state.open.set(file.fd, uri); state.positions.set(file.fd, 0); return file;
      },
      closeSync: file => { state.open.delete(file.fd); state.positions.delete(file.fd); },
      statSync: () => ({ size: state.selected.byteLength }),
      read: async (descriptor, buffer, options) => {
        assert.equal(state.open.get(descriptor), 'photo://screenshot');
        assert.equal(options.offset, undefined);
        const position = state.positions.get(descriptor);
        const count = Math.min(buffer.byteLength, 7);
        new Uint8Array(buffer).set(state.selected.subarray(position, position + count));
        state.positions.set(descriptor, position + count);
        return count;
      },
      writeSync: (descriptor, buffer) => buffer.byteLength, unlinkSync: () => {}
    } },
    '@ohos.multimedia.media': { default: { createAVPlayer: async () => {
      const handlers = {};
      return {
        on: (event, callback) => { handlers[event] = callback; },
        set fdSrc(value) { handlers.stateChange('initialized'); },
        prepare: async () => handlers.stateChange('prepared'),
        play: async () => { state.played++; if (!state.holdPlayback) handlers.stateChange('completed'); },
        release: async () => {}
      };
    } } }
  };
  function load(name) {
    if (cache[name]) return cache[name];
    if (name === 'LocalRuntime') return { LocalRuntime: class {
      constructor() { throw new Error('SmartServe must never start in cloud mode'); }
    } };
    if (name === 'LocalNeuralSpeech') return { LocalNeuralSpeech: {
      prepare: () => state.prepare(), synthesize: async (abilityContext, text, rate) => {
        assert.equal(abilityContext, context);
        state.speechRate = rate;
        await state.synthesize();
        state.speech.push(text);
        return new ArrayBuffer(44);
      }
    } };
    if (name === 'PhoneScreen' || name === 'CloudPhoneScreen') return { [name]: {
      status: async () => state.status,
      start: async (abilityContext, origin, interval) => {
        state.nativeStarts.push({ origin, interval }); return state.status;
      },
      stop: async () => { state.nativeStops++; },
      read: async after => {
        state.reads.push(after);
        return state.frame && state.frame.id !== after ? state.frame : undefined;
      }
    } };
    const file = path.join(root, 'entry/src/main/ets', name === 'CloudBattle' ? 'pages/CloudBattle.ets' : `demo/${name}.ets`);
    let source = fs.readFileSync(file, 'utf8');
    if (name === 'CloudBattle') source = (source.split('\n  build() {')[0] + '\n}')
      .replace(/^@(Entry|Component)\s*$/gm, '').replace(/@State\s*/g, '')
      .replace('struct CloudBattle {', 'export class CloudBattle {');
    const javascript = ts.transpileModule(source, { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
    } }).outputText;
    const sandbox = { exports: {}, console, getContext: () => context, SwiperController: class {},
      Date: class extends Date { static now() { return state.now; } },
      setTimeout: (callback, delay) => {
        if (delay > 500 && delay <= 6000) {
          const timer = ++timerSequence;
          timers.set(timer, callback);
          state.fireCloudDeadline = () => { timers.delete(timer); callback(); };
          return timer;
        }
        if (delay !== 500) return setTimeout(callback, delay);
        const timer = ++timerSequence; timers.set(timer, callback); return timer;
      },
      clearTimeout: timer => { if (!timers.delete(timer)) clearTimeout(timer); },
      require: key => key.startsWith('.') ? load(path.basename(key)) : mocks[key] || {}
    };
    vm.runInNewContext(javascript, sandbox, { filename: file });
    return cache[name] = sandbox.exports;
  }
  const page = new (load('CloudBattle').CloudBattle)();
  page.aboutToAppear();
  page.apiKey = 'test-key-never-log';
  page.roi = '0.1,0.1,0.3,0.5';
  return { state, page, load };
}

async function until(predicate) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await new Promise(resolve => setImmediate(resolve));
  }
  throw new Error('Expected asynchronous step was not reached');
}

async function main() {
  {
    const { page, state, load } = harness();
    state.savedSettings = new Map([['endpoint', 'https://legacy.example/v1'], ['apiKey', 'legacy-key']]);
    const restored = new (load('CloudBattle').CloudBattle)();
    restored.aboutToAppear();
    assert.equal(restored.apiKey, 'legacy-key');
    assert.equal(restored.roi, '0.025,0,0.168,0.325', 'default crop includes the map and protruding edge hero markers');
    assert.equal(restored.intervalText, '10');
    assert.equal(restored.allyColor, 'unknown');
    await until(() => !restored.savingCloudSettings);
    assert.equal(state.savedSettings.get('squareCrop'), false, 'legacy square output is disabled during migration');
    assert.equal(state.calls.length, 0);
    await page.importScreenshot();
    await load('CloudImages').cropCloudMinimap(state.selected, page.roi, state.now, 'padding-check', true);
    assert.equal(state.crops[0].size.width, 600, 'square output must retain the complete right edge of the selection');
    assert.equal(state.crops[0].size.height, 500);
    assert.equal(state.crops[0].x, 200);
    assert.equal(state.paddingCalls.length, 1, 'square output pads the short axis after the complete crop');
    assert.ok(page.sourceAspectRatio > 0);
    assert.equal(page.cropBounds[0], 0.1);
    page.roi = '0.1,0.1,0.25,0.5';
    page.cropChanged();
    assert.equal(page.preview, '', 'changing crop invalidates the old preview');
    await page.previewScreenshot();
    assert.ok(page.preview);
  }
  {
    const { state, load } = harness();
    state.savedSettings = new Map([['roi', '0,0,0.195,0.35'], ['squareCrop', true],
      ['imagePipelineVersion', 2], ['apiKey', 'keep-existing-key'], ['intervalText', '13']]);
    const restored = new (load('CloudBattle').CloudBattle)();
    restored.aboutToAppear();
    assert.equal(restored.roi, '0.025,0,0.168,0.325');
    assert.equal(restored.apiKey, 'keep-existing-key');
    assert.equal(restored.intervalText, '13');
    await until(() => !restored.savingCloudSettings);
    assert.equal(state.savedSettings.get('minimapPresetVersion'), 1);
    restored.aboutToDisappear();
    state.savedSettings = new Map([['roi', '0.04,0.01,0.17,0.32'], ['squareCrop', true],
      ['imagePipelineVersion', 2]]);
    const custom = new (load('CloudBattle').CloudBattle)();
    custom.aboutToAppear();
    assert.equal(custom.roi, '0.04,0.01,0.17,0.32', 'migration preserves a manually calibrated crop');
    await until(() => !custom.savingCloudSettings);
    assert.equal(state.savedSettings.get('squareCrop'), false, 'the removed square setting cannot affect custom crops');
    assert.equal(state.savedSettings.get('imagePipelineVersion'), 3);
  }
  {
    const { page, state } = harness();
    await page.importScreenshot();
    const before = Number(page.roi.split(',')[0]);
    page.adjustCrop(0.005, 0);
    await until(() => !page.busy);
    assert.ok(Math.abs(Number(page.roi.split(',')[0]) - before - 0.005) < 0.00001);
    assert.equal(state.crops[state.crops.length - 1].x, 210, 'right nudge updates the actual preview crop');
    page.adjustCrop(0, 0.005);
    await until(() => !page.busy);
    assert.equal(state.crops[state.crops.length - 1].size.width, 610);
    page.roi = '0.8,0,0.2,0.3';
    page.adjustCrop(0.005, 0.005);
    await until(() => !page.busy);
    const bounds = page.roi.split(',').map(Number);
    assert.ok(bounds[0] + bounds[2] <= 1, 'nudge and widening remain inside the source');
    page.useRecommendedCrop();
    await until(() => !page.busy);
    assert.equal(page.roi, '0.025,0,0.168,0.325');
    assert.equal(state.calls.length, 0, 'crop adjustments only preview locally');
  }
  {
    const { load } = harness();
    const quality = load('CloudImageQuality');
    const dark = new Uint8Array(40 * 20 * 4).fill(4);
    assert.equal(quality.inspectCloudPixels(dark, 40, 20).black, true);
    const bright = new Uint8Array(40 * 20 * 4).fill(100);
    assert.equal(quality.inspectCloudPixels(bright, 40, 20).black, false);
    assert.throws(() => quality.inspectCloudPixels(bright, 30, 20), /像素读取失败/);
  }
  for (const failure of ['rawBlack', 'cropBlack']) {
    const { page, state } = harness();
    state[failure] = true;
    await page.importScreenshot();
    assert.ok(page.imageIssue.includes(failure === 'rawBlack' ? '原始录屏帧' : '小地图区域全黑'));
    assert.ok(page.sourcePreview, 'the original thumbnail is available to diagnose the failure');
    await page.analyzeScreenshot();
    assert.equal(state.calls.length, 0, 'black images must never incur a cloud request');
    assert.equal(state.played, 0, 'black images must never speak the fallback repeatedly');
    assert.equal(page.count, 0);
  }
  {
    const { page, state } = harness();
    state.visibleRect = [0.25, 0, 0.5, 1];
    await page.importScreenshot();
    assert.equal(state.crops[0].x, 200, 'static ROI must retain original image coordinates even when black borders exist');
    assert.equal(state.crops[0].size.width, 600, 'static ROI must not be heuristically resized');
    assert.equal(state.decoderOptions.length, 1, 'static crop must use one full resolution decode');
    assert.equal(state.decoderOptions[0].desiredSize, undefined);
    assert.equal(Buffer.from(page.sourcePreview.split(',')[1], 'base64').toString(),
      'FULL_SCREEN_SHOULD_NEVER_BE_UPLOADED', 'original preview must preserve the original encoded image');
    assert.equal(page.imageIssue, '');
    await page.analyzeScreenshot();
    assert.equal(state.played, 1);
  }
  {
    const { page, state } = harness();
    await page.start();
    state.rawBlack = true;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'black' };
    await page.tick(page.sequence);
    assert.equal(page.running, true, 'a black frame should wait for the game, not stop capture');
    assert.equal(state.calls.length, 0);
    state.rawBlack = false;
    state.now += 10000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'recovered' };
    await page.tick(page.sequence);
    assert.equal(page.imageIssue, '');
    assert.equal(state.played, 1, 'capture must recover automatically from a transient black frame');
    assert.equal(state.calls[0].body.messages[1].content.filter(part => part.type === 'image_url').length, 1);
    await page.stop();
  }
  for (const color of ['blue', 'red']) {
    const { page, state, load } = harness();
    page.allyColor = color;
    await page.importScreenshot();
    await page.analyzeScreenshot();
    const prompt = state.calls[0].body.messages[0].content;
    assert.ok(prompt.includes(color === 'blue' ? '蓝色英雄标记边框为我方' : '红色英雄标记边框为我方'));
    assert.ok(prompt.includes(color === 'blue' ? '红色头像配蓝环仍是我方' : '蓝色头像配红环仍是我方'));
    assert.ok(prompt.includes(color === 'blue' ? '蓝色头像配红环仍是敌方' : '红色头像配蓝环仍是敌方'));
    assert.match(prompt, /灰色部分不改变阵营/);
    assert.match(prompt, /外环全灰、遮挡或红蓝不清时不猜阵营/);
    assert.match(prompt, /血量只看外环亮色与灰色占比/);
    assert.match(prompt, /不能由头像整体发暗判断血量/);
    assert.match(prompt, /不报百分比、死亡或据此建议追击/);
    const instruction = state.calls[0].body.messages[1].content.find(part => part.type === 'text').text;
    assert.match(instruction, /以剩余红蓝弧段判敌我，不看头像本身颜色/);
    assert.match(prompt, /录屏红点.*无论在地图内外都不计英雄/);
    assert.match(prompt, /每个计数都要对应独立可辨的头像与外环/);
    assert.match(prompt, /屏幕左上角不等于上路/);
    assert.match(prompt, /没有明确英雄风险就不提醒/);
    assert.ok(!prompt.includes('两名敌方英雄'), 'a concrete hero count must not become a copied answer');
    assert.match(instruction, /忽略录屏红点、状态栏和小兵/);
    assert.ok(prompt.length < 1000);
    assert.ok(prompt.length + instruction.length < 1100, 'ring guidance must keep a compact input budget');
    assert.match(prompt, /上路、中路、下路/);
    assert.match(prompt, /不能只凭未见敌人猜埋伏/);
    const api = load('CloudBattleApi');
    assert.throws(() => api.normalizeCloudBriefing('中'.repeat(33)), /简短中文/);
    assert.equal(api.normalizeCloudBriefing('下路需要支援，先别压线。'), '下路需要支援，先别压线。');
    assert.throws(() => api.validateCloudConfig({ endpoint: page.endpoint, apiKey: page.apiKey,
      model: page.model, allyColor: 'untrusted prompt override' }), /配色/);
  }
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root,
    'entry/src/main/resources/base/profile/main_pages.json'), 'utf8')).src, ['pages/CloudBattle']);
  assert.match(fs.readFileSync(path.join(root, 'entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8'),
    /loadContent\('pages\/CloudBattle'/);
  {
    const { page, state, load } = harness();
    page.endpoint = 'https://cloud.example/compatible-mode/v1';
    page.apiKey = 'saved-test-key';
    page.model = 'saved-vision-model';
    page.roi = '0.01,0.02,0.19,0.34';
    page.intervalText = '17';
    page.speechRate = 1.18;
    page.allyColor = 'red';
    page.saveCloudSettings();
    await until(() => !page.savingCloudSettings);
    page.aboutToDisappear();
    assert.equal(page.apiKey, '', 'leaving the page must clear its in-memory key');
    const restored = new (load('CloudBattle').CloudBattle)();
    restored.aboutToAppear();
    assert.equal(restored.endpoint, 'https://cloud.example/compatible-mode/v1');
    assert.equal(restored.apiKey, 'saved-test-key', 'a new page must restore the saved key');
    assert.equal(restored.model, 'saved-vision-model');
    assert.equal(restored.roi, '0.01,0.02,0.19,0.34');
    assert.equal(restored.intervalText, '17');
    assert.equal(restored.speechRate, 1.18);
    assert.equal(restored.allyColor, 'red');
    assert.equal(state.savedSettings.get('squareCrop'), false);
    assert.equal(state.calls.length, 0, 'restoring credentials must not send a cloud request');
    restored.endpoint = '';
    restored.apiKey = '';
    restored.model = '';
    restored.roi = '';
    restored.intervalText = '';
    restored.allyColor = 'unknown';
    restored.saveCloudSettings();
    await until(() => !restored.savingCloudSettings);
    const cleared = new (load('CloudBattle').CloudBattle)();
    cleared.aboutToAppear();
    assert.equal(cleared.endpoint, '', 'an explicitly cleared URL must stay cleared');
    assert.equal(cleared.apiKey, '', 'an explicitly cleared key must stay cleared');
    assert.equal(cleared.model, '');
    assert.equal(cleared.roi, '');
    assert.equal(cleared.intervalText, '');
    assert.equal(cleared.allyColor, 'unknown');
  }
  {
    const { page, state, load } = harness();
    let releaseFlush;
    const delayedFlush = new Promise(resolve => { releaseFlush = resolve; });
    let flushCount = 0;
    state.flushSettings = async () => {
      flushCount++;
      if (flushCount === 1) await delayedFlush;
    };
    page.endpoint = 'https://first.example/v1';
    page.apiKey = 'first-key';
    page.intervalText = '12';
    page.saveCloudSettings();
    page.endpoint = 'https://latest.example/v1';
    page.apiKey = 'latest-key';
    page.intervalText = '23';
    page.saveCloudSettings();
    page.aboutToDisappear();
    releaseFlush();
    await until(() => !page.savingCloudSettings);
    const restored = new (load('CloudBattle').CloudBattle)();
    restored.aboutToAppear();
    assert.equal(restored.endpoint, 'https://latest.example/v1');
    assert.equal(restored.apiKey, 'latest-key', 'a pending save must retain the latest key after leaving');
    assert.equal(restored.intervalText, '23', 'pending saves must retain the latest interval too');
  }
  {
    const { page, state } = harness();
    state.flushSettings = async () => { throw new Error('simulated storage failure'); };
    page.saveCloudSettings();
    await until(() => !page.savingCloudSettings);
    assert.ok(page.settingsError.includes('保存失败'));
    assert.ok(!page.settingsError.includes(page.apiKey), 'storage errors must not expose the key');
    state.flushSettings = async () => {};
    page.saveCloudSettings();
    await until(() => !page.savingCloudSettings);
    assert.equal(page.settingsError, '');
    assert.equal(state.savedSettings.get('apiKey'), page.apiKey);
  }
  {
    const { page, state, load } = harness();
    const api = load('CloudBattleApi');
    assert.equal(api.cloudChatUrl('https://cloud.example'), 'https://cloud.example/v1/chat/completions');
    assert.equal(api.cloudChatUrl('https://cloud.example/compatible-mode/v1/'),
      'https://cloud.example/compatible-mode/v1/chat/completions');
    assert.equal(api.cloudChatUrl('https://cloud.example/v1/chat/completions'),
      'https://cloud.example/v1/chat/completions');
    for (const endpoint of ['http://cloud.example', 'https://key@cloud.example', 'https://cloud.example/?key=secret']) {
      assert.throws(() => api.cloudChatUrl(endpoint), /HTTPS/);
    }
    await page.importScreenshot();
    assert.equal(state.calls.length, 0, 'preview must not upload');
    assert.equal(state.open.size, 0, 'selected screenshot descriptor must be closed');
    assert.equal(state.crops[0].x, 200);
    assert.equal(state.crops[0].y, 100);
    assert.equal(state.crops[0].size.width, 600);
    assert.equal(state.crops[0].size.height, 500);
    await page.analyzeScreenshot();
    assert.equal(page.count, 1);
    assert.equal(page.reply, briefing);
    assert.equal(state.played, 1);
    assert.deepEqual(state.speech, [briefing]);
    assert.equal(state.open.size, 0);
    const call = state.calls[0];
    assert.equal(call.options.header.Authorization, 'Bearer test-key-never-log');
    assert.equal(call.body.model, 'qwen3.6-flash');
    assert.equal(call.body.enable_thinking, false);
    assert.equal(call.body.stream, false);
    assert.equal(call.body.temperature, 0.1);
    assert.equal(call.body.max_tokens, 96);
    assert.match(call.body.messages[0].content, /单张图不能声称消失/);
    assert.match(call.body.messages[0].content, /用户尚未校准敌我配色/);
    const images = call.body.messages[1].content.filter(part => part.type === 'image_url');
    assert.equal(images.length, 1);
    assert.equal(Buffer.from(images[0].image_url.url.split(',')[1], 'base64').toString(), 'CROPPED_JPEG');
    assert.ok(!call.options.extraData.includes(Buffer.from('SOURCE_THUMBNAIL_LOCAL_ONLY').toString('base64')));
    assert.ok(!call.options.extraData.includes(Buffer.from(state.selected).toString('base64')),
      'original full resolution preview must remain local and never appear in the cloud request');
    assert.equal(state.nativeStarts.length, 0, 'import must not start screen capture or SmartServe');
  }
  {
    const { page, state } = harness();
    await page.importScreenshot();
    assert.equal(page.hasScreenshot, true);
    await page.start();
    assert.equal(page.running, true);
    assert.equal(page.hasScreenshot, false, 'live previews must never be presented as the selected static screenshot');
    assert.equal(page.selected, undefined);
    assert.equal(state.nativeStarts[0].origin, '', 'native uploader must stay disabled');
    assert.equal(state.nativeStarts[0].interval, 1000, 'local capture cadence is independent of the paid cloud interval');
    page.allyColor = 'red';
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'live-1' };
    await page.tick(page.sequence);
    assert.equal(state.crops[state.crops.length - 1].size.width, 600, 'live run must retain its original crop settings');
    assert.match(state.calls[0].body.messages[0].content, /用户尚未校准敌我配色/);
    state.now += 10000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'live-2' };
    await page.tick(page.sequence);
    assert.equal(page.count, 1, 'identical live reminders must not repeat within 20 seconds');
    assert.equal(state.calls[1].body.messages[1].content.filter(part => part.type === 'image_url').length, 1,
      'each request contains only the newest map, including after the first live frame');
    state.width = 1800;
    state.now += 10000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'live-3' };
    await page.tick(page.sequence);
    assert.equal(state.calls[2].body.messages[1].content.filter(part => part.type === 'image_url').length, 1);
    assert.equal(page.count, 2, 'a persistent reminder can be spoken again after its cooldown');
    state.status.privateScene = true;
    await page.tick(page.sequence);
    assert.equal(state.calls.length, 3, 'privacy scene must not upload');
    await page.stop();
  }
  {
    const { page, state } = harness();
    page.allyColor = 'blue';
    await page.start();
    state.content = '小地图暂无明确动向。';
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'quiet' };
    await page.tick(page.sequence);
    assert.equal(page.reply, state.content, 'quiet observations are still shown in the page');
    assert.equal(state.played, 0);
    assert.equal(state.calls[0].body.messages[1].content.filter(part => part.type === 'image_url').length, 1);
    state.content = '下路敌人抱团，先往塔下靠。';
    state.now += 10000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'new-risk' };
    await page.tick(page.sequence);
    assert.equal(state.played, 1, 'a new warning must immediately break quiet mode');
    state.content = '中路敌人聚集，先保持距离。';
    state.now += 10000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'different-risk' };
    await page.tick(page.sequence);
    assert.equal(state.played, 2, 'a different location must not be suppressed by the previous warning');
    state.content = '画面不清，暂不判断。';
    state.now += 10000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'unclear' };
    await page.tick(page.sequence);
    assert.equal(state.played, 2);
    assert.equal(state.calls[3].body.messages[1].content.filter(part => part.type === 'image_url').length, 1);
    await page.stop();
    await page.importScreenshot();
    await page.analyzeScreenshot();
    await page.analyzeScreenshot();
    assert.equal(state.played, 4, 'static analyses can replay even an uncertainty message');
  }
  {
    const { page, state } = harness();
    page.apiKey = '';
    page.endpoint = '';
    page.speechRate = 1.18;
    await page.previewVoice();
    assert.equal(state.calls.length, 0, 'voice preview must not contact the cloud');
    assert.equal(state.nativeStarts.length, 0, 'voice preview must not start recording');
    assert.equal(state.speechRate, 1.18);
    assert.equal(state.played, 1);
    assert.equal(page.busy, false);
    assert.match(page.status, /示例/);
  }
  {
    const { page, state } = harness();
    await page.importScreenshot();
    let finish;
    state.respond = () => new Promise(resolve => { finish = resolve; });
    const pending = page.analyzeScreenshot();
    await until(() => Boolean(finish));
    await page.analyzeScreenshot();
    assert.equal(state.calls.length, 1, 'no overlapping requests');
    await page.stop();
    finish();
    await pending;
    assert.equal(page.count, 0);
    assert.equal(state.speech.length, 0, 'cancelled response must not reach TTS');
  }
  {
    const { page, state } = harness();
    let finish;
    state.prepare = () => new Promise(resolve => { finish = resolve; });
    const pending = page.start();
    await until(() => Boolean(finish));
    await page.stop();
    finish();
    await pending;
    assert.equal(state.nativeStarts.length, 0, 'cancelled startup must not start capture');
    assert.equal(page.running, false);
  }
  for (const failure of ['http', 'text', 'tts', 'expired']) {
    const { page, state } = harness();
    await page.importScreenshot();
    if (failure === 'http') { state.responseCode = 401; state.content = 'test-key-never-log'; }
    if (failure === 'text') state.content = 'not a Chinese battlefield observation';
    if (failure === 'tts') state.synthesize = async () => { throw new Error('TTS failure'); };
    if (failure === 'expired') state.synthesize = async () => { state.now += 31000; };
    state.usage = { prompt_tokens: 800, completion_tokens: 15 };
    await page.analyzeScreenshot();
    assert.equal(page.count, 0, failure);
    assert.equal(state.played, 0, failure);
    assert.match(page.status, /失败/);
    assert.equal(page.status.includes('test-key-never-log'), false);
    assert.equal(state.open.size, 0);
    assert.match(page.analysisReport, /本次云端请求1次/, 'failed work remains counted as a potentially billed request');
    if (failure !== 'http') assert.match(page.analysisReport, /输入800、输出15/);
  }
  {
    const { page, state } = harness();
    state.status.supported = false;
    state.status.state = 'unsupported';
    await page.start();
    assert.equal(page.running, false);
    assert.equal(state.calls.length, 0);
    await page.importScreenshot();
    await page.analyzeScreenshot();
    assert.equal(page.count, 1, 'manual screenshot flow works without screen capture APIs');
  }
  {
    const { page, state } = harness();
    await page.start();
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now - 31000, id: 'old' };
    await page.tick(page.sequence);
    assert.equal(state.calls.length, 0, 'old screenshot must not be sent');
    assert.equal(page.running, true, 'expired live frames are skipped without stopping the recording');
    assert.equal(page.count, 0);
    await page.stop();
  }
  {
    const { page, state } = harness();
    await page.importScreenshot();
    state.respond = async () => { state.now += 31000; };
    await page.analyzeScreenshot();
    assert.equal(state.speech.length, 0, 'response arriving after the deadline must not reach TTS');
    assert.equal(page.count, 0);
  }
  {
    const { page, state } = harness();
    await page.start();
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'privacy-change' };
    state.respond = async () => { state.status.privateScene = true; };
    await page.tick(page.sequence);
    assert.equal(state.speech.length, 0, 'privacy change during the request must stop playback');
    assert.equal(page.running, false);
  }
  {
    const { page, state } = harness();
    await page.importScreenshot();
    state.holdPlayback = true;
    const pending = page.analyzeScreenshot();
    await until(() => state.played === 1);
    await page.stop();
    await pending;
    assert.equal(page.count, 0, 'cancelled audio must not count as completed playback');
    assert.equal(state.open.size, 0, 'cancelled audio must release its file');
  }
  {
    const { page, state } = harness();
    await page.start();
    assert.deepEqual(state.backgroundModes, ['audioRecording', 'audioPlayback']);
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'background-game' };
    await page.tick(page.sequence);
    assert.equal(page.count, 1, 'live capture must reach cloud analysis and audible playback');
    assert.equal(state.played, 1);
    assert.equal(state.audioSessions, 0, 'completed playback must release its audio session');
    await page.stop();
    assert.equal(state.backgroundStops, 1);
  }
  {
    const { page, state } = harness();
    await page.start();
    state.now += 31000;
    await page.tick(page.sequence);
    assert.equal(page.running, false, 'missing native frames must not wait silently forever');
    assert.match(page.status, /没有新截图/);
  }
  {
    const { page, state } = harness();
    page.intervalText = '300';
    await page.start();
    state.now += 31000;
    await page.tick(page.sequence);
    assert.equal(page.running, true, 'frame timeout must respect the configured capture interval');
    await page.stop();
  }
  {
    const { page, state } = harness();
    await page.start();
    state.status.error = 'Unsupported video layout';
    await page.tick(page.sequence);
    assert.match(page.status, /Unsupported video layout/);
    assert.equal(page.running, false);
  }
  {
    const { page, state } = harness();
    state.notify = async () => { throw new Error('notification permission denied'); };
    await page.start();
    assert.equal(page.running, false);
    assert.equal(state.nativeStarts.length, 0);
    assert.match(page.status, /notification permission denied/);
  }
  {
    const { page, state } = harness();
    await page.start();
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'budget-first' };
    await page.tick(page.sequence);
    const firstPreview = page.preview;
    const firstPreviewTime = page.previewCapturedAt;
    assert.equal(firstPreviewTime, new Date(state.now).toTimeString().slice(0, 8));
    assert.equal(page.reply, briefing);
    page.intervalText = '1';
    state.now += 1000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'budget-skipped' };
    await page.tick(page.sequence);
    assert.equal(state.calls.length, 1, 'new local frames do not create extra paid requests');
    assert.equal(state.reads.length, 1, 'read only the newest frame when a cloud request is due');
    assert.equal(page.preview, firstPreview, 'the upload preview stays on the frame actually analyzed');
    assert.equal(page.previewCapturedAt, firstPreviewTime);
    state.now += 9000;
    state.packedCrop = 'LATEST_CROPPED_JPEG';
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'budget-newest' };
    let finishRequest;
    state.respond = () => new Promise(resolve => { finishRequest = resolve; });
    const updating = page.tick(page.sequence);
    await until(() => state.calls.length === 2);
    assert.equal(page.reply, '', 'a new image must not display the previous frame caption');
    assert.notEqual(page.preview, firstPreview);
    assert.equal(page.preview, state.calls[1].body.messages[1].content.find(part => part.type === 'image_url').image_url.url);
    assert.equal(page.previewCapturedAt, new Date(state.frame.capturedAt).toTimeString().slice(0, 8));
    state.content = '小地图暂无明确动向。';
    finishRequest();
    await updating;
    assert.equal(page.reply, state.content);
    assert.equal(state.played, 1, 'a quiet new frame must not repeat the earlier risk reminder');
    assert.equal(state.calls.length, 2);
    assert.equal(page.lastId, 'budget-newest');
    assert.ok(state.calls[1].at - state.calls[0].at >= 10000, 'the running interval uses its saved snapshot');
    await page.stop();
  }
  for (const stage of ['cloud', 'speech']) {
    const { page, state } = harness();
    await page.start();
    const capturedAt = state.now;
    state.frame = { bytes: state.selected.buffer, capturedAt, id: 'slow-' + stage };
    if (stage === 'cloud') state.respond = async () => { state.now += 8500; };
    else state.synthesize = async () => { state.now += 8500; };
    state.usage = { prompt_tokens: 900, completion_tokens: 16 };
    await page.tick(page.sequence);
    assert.equal(state.played, 0, stage + ' must not start stale audio');
    assert.equal(page.running, true, 'stale work is skipped while recording remains active');
    assert.equal(page.count, 0);
    assert.match(page.analysisReport, /输入900、输出16/);
    state.now = capturedAt + 9000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'too-early-retry' };
    await page.tick(page.sequence);
    assert.equal(state.calls.length, 1, 'discarding a stale response must not trigger a paid retry');
    state.respond = async () => {};
    state.synthesize = async () => {};
    state.now = capturedAt + 10000;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'fresh-recovery' };
    await page.tick(page.sequence);
    assert.equal(state.played, 1, 'the next allowed fresh frame recovers normally');
    assert.equal(state.calls.length, 2);
    await page.stop();
  }
  {
    const { page, state } = harness();
    await page.start();
    state.respond = () => new Promise(() => {});
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'never-returns' };
    const processing = page.tick(page.sequence);
    await until(() => Boolean(state.fireCloudDeadline));
    state.now += 6001;
    state.fireCloudDeadline();
    await processing;
    assert.equal(page.running, true);
    assert.equal(state.played, 0);
    assert.ok(state.destroyedRequests > 0, 'deadline must destroy the pending HTTP request');
    assert.match(page.status, /实时预算/);
    assert.match(page.analysisReport, /尚未返回token用量/);
    state.now += 500;
    await page.tick(page.sequence);
    assert.equal(state.calls.length, 1);
    await page.stop();
  }
  for (const invalid of ['下路三个红色小兵，先撤退。', '中路三个红点，可能是敌人。',
    '左上角录屏红点，注意敌人。', '录制按钮旁有两名敌方英雄。', '状态栏有红色圆圈，可能是敌人。',
    '下路疑似英雄聚集，先撤退。', '敌方英雄消失，留意河道。',
    '敌方英雄转线，留意下路。', '河道正在交战，赶快支援。']) {
    const { page, state } = harness();
    page.allyColor = 'blue';
    await page.start();
    state.content = invalid;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'untrusted-identity' };
    await page.tick(page.sequence);
    assert.equal(state.played, 0, invalid);
    assert.equal(page.reply, '画面不清，暂不判断。');
    assert.equal(page.running, true);
    await page.stop();
  }
  for (const color of ['blue', 'red']) {
    for (const reminder of ['我方野区有敌方英雄，注意防守。', '下路塔旁有敌方英雄，及时守塔。',
      '河道我方人数劣势，附近注意支援。', '下路河道有敌方英雄，线上防抓。', '上路我方残血，先靠塔。']) {
      const { page, state } = harness();
      page.allyColor = color;
      await page.start();
      state.content = reminder;
      state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'tactical-reminder' };
      await page.tick(page.sequence);
      assert.equal(page.reply, reminder);
      assert.deepEqual(state.speech, [reminder], 'supported tactical wording must reach local speech');
      assert.equal(state.played, 1);
      assert.equal(state.calls.length, 1);
      const request = state.calls[0].body;
      assert.equal(request.messages[1].content.filter(part => part.type === 'image_url').length, 1);
      assert.equal(request.max_tokens, 96);
      await page.stop();
    }
  }
  for (const reminder of ['下路两名敌方英雄，先靠塔。', '上路我方残血，先靠塔。']) {
    const { page, state } = harness();
    await page.start();
    state.content = reminder;
    state.frame = { bytes: state.selected.buffer, capturedAt: state.now, id: 'unknown-colors' };
    await page.tick(page.sequence);
    assert.equal(state.played, 0, 'uncalibrated colors cannot yield enemy claims even if the model ignores the prompt');
    await page.stop();
  }
  {
    const { page, state, load } = harness();
    const prompt = load('GamePrompt').cloudBattlePrompt('blue');
    assert.match(prompt, /人物头像.*独立圆形头像外圈/);
    assert.match(prompt, /红色不等于敌方英雄/);
    assert.match(prompt, /不将小兵数量用于人数优势/);
    assert.match(prompt, /野区入侵：.*确认我方野区/);
    assert.match(prompt, /偷塔风险：.*我方防御塔/);
    assert.match(prompt, /团战支援：.*我方人数劣势/);
    assert.match(prompt, /被抓风险：.*邻近我方线上英雄/);
    assert.match(prompt, /消失需要前后帧证据/);
    assert.ok(prompt.length < 1000, 'tactical criteria must stay within a compact prompt budget');
    state.usage = { prompt_tokens: 1234, completion_tokens: 17 };
    await page.importScreenshot();
    state.respond = async () => { state.now += 10000; };
    await page.analyzeScreenshot();
    assert.equal(state.played, 1, 'static analysis keeps its explicitly non-live deadline');
    assert.match(page.analysisReport, /输入1234、输出17/);
    assert.equal(page.api.stats().usageResponses, 1);
    assert.equal(state.calls[0].body.max_tokens, 96);
    state.usage = { prompt_tokens: -1, completion_tokens: 'unknown' };
    state.respond = async () => {};
    await page.analyzeScreenshot();
    assert.equal(page.api.stats().usageResponses, 0, 'missing or invalid usage must remain unknown, not estimated');
    assert.match(page.analysisReport, /尚未返回token用量/);
  }
  console.log('cloud battlefield flow: persistent settings, full crop, latest single image, request budget, live deadlines, cautious hero-only tactical reminders, token usage, mixed audio, cancellation and recovery passed');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
