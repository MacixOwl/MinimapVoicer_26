const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/demo/CaptureInterval.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017 }
}).outputText;
const context = { exports: {} };
vm.runInNewContext(compiled, context);
const { parseCaptureIntervalMs, DEFAULT_CAPTURE_INTERVAL_SECONDS } = context.exports;
assert.equal(parseCaptureIntervalMs(String(DEFAULT_CAPTURE_INTERVAL_SECONDS)), 10000);
for (const [text, expected] of [['1', 1000], ['5', 5000], ['30', 30000],
  ['300', 300000], [' 10 ', 10000]]) {
  assert.equal(parseCaptureIntervalMs(text), expected);
}
for (const text of ['', ' ', '0', '-1', '301', '1.5', '1e2', 'Infinity', 'NaN', '10秒']) {
  assert.throws(() => parseCaptureIntervalMs(text), /1～300/);
}
console.log('PASS: capture interval defaults, seconds-to-ms, boundaries and invalid user input');
