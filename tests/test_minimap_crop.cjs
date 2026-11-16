const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const filename = path.join(__dirname, '../entry/src/main/ets/demo/MinimapCrop.ets');
const source = fs.readFileSync(filename, 'utf8');
const javascript = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
} }).outputText;
const sandbox = { exports: {} };
vm.runInNewContext(javascript, sandbox, { filename });
const { padMinimapRgba } = sandbox.exports;

for (const [width, height] of [[9, 5], [5, 9], [8, 3], [3, 8], [4, 4]]) {
  const pixels = new Uint8Array(width * height * 4);
  for (let index = 0; index < pixels.length; index++) pixels[index] = index % 251;
  const padded = padMinimapRgba(pixels, width, height);
  const side = Math.max(width, height);
  const left = Math.floor((side - width) / 2);
  const top = Math.floor((side - height) / 2);
  assert.equal(padded.length, side * side * 4);
  for (let row = 0; row < height; row++) {
    assert.deepEqual(Array.from(padded.slice(((top + row) * side + left) * 4,
      ((top + row) * side + left + width) * 4)), Array.from(pixels.slice(row * width * 4, (row + 1) * width * 4)),
    'every source pixel, including the rightmost lane, must survive square padding unchanged');
  }
  if (width !== height) assert.equal(padded[3], 255, 'padding is opaque');
}
assert.throws(() => padMinimapRgba(new Uint8Array(0), 0, 1), /尺寸无效/);
assert.throws(() => padMinimapRgba(new Uint8Array(4), 513, 1), /尺寸无效/);
assert.throws(() => padMinimapRgba(new Uint8Array(4), 2, 1), /尺寸无效/);
console.log('PASS: square padding preserves all minimap RGBA pixels for landscape, portrait and odd dimensions');
