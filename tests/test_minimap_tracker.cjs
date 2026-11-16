const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const root = path.join(__dirname, '..');
function load(name) {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/demo', name + '.ets'), 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017 }
  }).outputText;
  const context = { exports: {} };
  vm.runInNewContext(compiled, context);
  return context.exports;
}
const { MinimapTracker, parseMapObservation, parseMinimapRoi } = load('MinimapTracker');
const { normalizeBroadcast } = load('BroadcastPolicy');
const passed = [];
function test(name, run) { run(); passed.push(name); console.log('PASS:', name); }
const grid = (region = 0, count = 0) => {
  const cells = Array(9).fill(0);
  cells[region] = count;
  return { readable: true, confidence: 0.95, cells };
};
const observe = (tracker, value, time, geometry = 'landscape') =>
  tracker.observe(value, time, time + 100, geometry);

test('schema rejects hallucinated counts, incomplete data and invalid JSON', () => {
  assert.ok(parseMapObservation(JSON.stringify(grid())));
  assert.ok(parseMapObservation('```json\n' + JSON.stringify(grid()) + '\n```'));
  assert.ok(parseMapObservation(JSON.stringify({ ...grid(), cells: [[0, 0, 0], [0, 1, 0], [0, 0, 0]] })));
  assert.ok(parseMapObservation(JSON.stringify({ ...grid(), cells: [Array(9).fill(0)] })));
  for (const value of [
    { ...grid(), cells: [0] }, { ...grid(), cells: Array(9).fill(1) },
    { ...grid(), confidence: 2 }, { ...grid(), cells: [1.5, ...Array(8).fill(0)] },
    { ...grid(), readable: 'true' }
  ]) assert.equal(parseMapObservation(JSON.stringify(value)), undefined);
  for (const text of ['null', 'not JSON', '```json\n{}\n```', '<think>xx</think>{}'])
    assert.equal(parseMapObservation(text), undefined);
});
test('ROI rejects empty, negative, tiny-invalid and out-of-screen coordinates', () => {
  assert.equal(parseMinimapRoi('0,0,0.22,0.36').join(','), '0,0,0.22,0.36');
  for (const text of [',0,.2,.3', '0,0,0,.3', '-.1,0,.2,.3', '.9,0,.2,.3', '0,0,1', 'a,0,.2,.3'])
    assert.throws(() => parseMinimapRoi(text));
});
test('first frame and unchanged frames stay silent', () => {
  const tracker = new MinimapTracker();
  for (const time of [0, 10000, 20000]) assert.equal(observe(tracker, grid(), time).text, '');
});
test('a one-frame false positive does not produce speech', () => {
  const tracker = new MinimapTracker();
  observe(tracker, grid(), 0);
  assert.equal(observe(tracker, grid(8, 2), 10000).text, '');
  assert.equal(observe(tracker, grid(), 20000).text, '');
});
test('two consistent changes confirm a concentration and use fixed short wording', () => {
  const tracker = new MinimapTracker();
  observe(tracker, grid(), 0);
  assert.equal(observe(tracker, grid(8, 2), 10000).text, '');
  assert.equal(observe(tracker, grid(8, 2), 20000).text, '小地图右下敌方标记聚集，注意。');
  assert.equal(observe(tracker, grid(8, 2), 30000).text, '');
});
test('a decrease describes visible markers without inventing enemy movement', () => {
  const tracker = new MinimapTracker();
  observe(tracker, grid(0, 2), 0);
  observe(tracker, grid(), 10000);
  const text = observe(tracker, grid(), 20000).text;
  assert.equal(text, '小地图左上敌方可见标记减少，留意视野。');
  assert.equal(normalizeBroadcast(text), text);
});
test('unreadable, uncertain, stale and future frames break the comparison baseline', () => {
  for (const kind of ['unreadable', 'confidence', 'invalid', 'stale', 'future']) {
    const tracker = new MinimapTracker();
    observe(tracker, grid(0, 2), 0);
    let value = grid();
    if (kind === 'unreadable') value.readable = false;
    if (kind === 'confidence') value.confidence = 0.5;
    if (kind === 'invalid') value = undefined;
    const now = kind === 'stale' ? 26000 : kind === 'future' ? 9000 : 10100;
    assert.equal(tracker.observe(value, 10000, now, 'landscape').text, '');
    assert.equal(observe(tracker, grid(), 30000).text, '', kind);
  }
});
test('rotation, a long gap and explicit reset rebuild the baseline', () => {
  for (const kind of ['rotation', 'gap', 'reset']) {
    const tracker = new MinimapTracker();
    observe(tracker, grid(), 0);
    observe(tracker, grid(8, 2), 10000);
    if (kind === 'reset') tracker.reset();
    assert.equal(observe(tracker, grid(8, 2), kind === 'gap' ? 50000 : 20000,
      kind === 'rotation' ? 'portrait' : 'landscape').text, '');
  }
});
test('same event is suppressed within 45 seconds and distinct events respect cooldown', () => {
  const tracker = new MinimapTracker();
  observe(tracker, grid(), 0);
  observe(tracker, grid(8, 2), 10000);
  assert.ok(observe(tracker, grid(8, 2), 20000).text);
  observe(tracker, grid(0, 1), 21000);
  assert.equal(observe(tracker, grid(0, 1), 22000).text, '');
  observe(tracker, grid(8, 2), 30000);
  assert.equal(observe(tracker, grid(8, 2), 40000).text, '');
});
test('all region/event templates pass the 25-character broadcast policy', () => {
  for (let region = 0; region < 9; ++region) {
    for (const [before, after] of [[0, 1], [0, 2], [2, 0]]) {
      const tracker = new MinimapTracker();
      observe(tracker, grid(region, before), 0);
      observe(tracker, grid(region, after), 10000);
      const text = observe(tracker, grid(region, after), 20000).text;
      assert.ok(text);
      assert.equal(normalizeBroadcast(text), text);
      assert.ok(Array.from(text).length <= 25);
    }
  }
});
if (process.argv.includes('--write-report')) fs.writeFileSync(
  path.join(root, 'artifacts/minimap-rule-verification.json'),
  JSON.stringify({ tested_at: new Date().toISOString(), passed: passed.length, cases: passed,
    observations: 'synthetic structured inputs, not game image recognition',
    phone_tested: false }, null, 2) + '\n');
