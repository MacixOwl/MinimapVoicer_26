const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

let now = 100000;
const filename = path.join(__dirname, '../entry/src/main/ets/demo/CloudTiming.ets');
const sandbox = { exports: {}, Date: class extends Date { static now() { return now; } } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(filename, 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
} }).outputText, sandbox, { filename });
const { assertCloudFrameFresh, liveRequestBudgetMs, CloudFrameExpiredError,
  LIVE_CAPTURE_INTERVAL_MS, LIVE_FRAME_MAX_AGE_MS } = sandbox.exports;

assert.equal(LIVE_CAPTURE_INTERVAL_MS, 1000);
assert.equal(LIVE_FRAME_MAX_AGE_MS, 8000);
assert.equal(liveRequestBudgetMs(now), 6000);
assert.equal(liveRequestBudgetMs(now - 3000), 4000, 'network budget reserves one second for speech');
assert.equal(liveRequestBudgetMs(now - 6500), 500);
assert.throws(() => liveRequestBudgetMs(now - 7000), CloudFrameExpiredError);
assertCloudFrameFresh(now - 8000, LIVE_FRAME_MAX_AGE_MS);
assert.throws(() => assertCloudFrameFresh(now - 8001, LIVE_FRAME_MAX_AGE_MS), CloudFrameExpiredError);
assertCloudFrameFresh(now - 30000);
assert.throws(() => assertCloudFrameFresh(now - 30001), CloudFrameExpiredError);
for (const invalid of [NaN, Infinity, now + 2001]) {
  assert.throws(() => assertCloudFrameFresh(invalid), CloudFrameExpiredError);
}
now -= 10000;
assert.throws(() => assertCloudFrameFresh(100000), CloudFrameExpiredError, 'clock rollback cannot revive future frames');
console.log('PASS: independent local cadence, bounded live network budget, speech reserve and static/live freshness boundaries');
