const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/demo/BroadcastPolicy.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017 }
}).outputText;
const context = { exports: {} };
vm.runInNewContext(compiled, context);
const { normalizeBroadcast, BROADCAST_FALLBACK, MAX_BROADCAST_CHARACTERS } = context.exports;
const valid = ['这是一条测试播报。', '请留意小地图。', '画面左侧有红色标记。'];
for (const input of valid) assert.equal(normalizeBroadcast(input), input);
assert.equal(normalizeBroadcast('提醒：请留意小地图。'), '请留意小地图。');
assert.equal(normalizeBroadcast('<think>分析</think>请留意小地图。'), '请留意小地图。');
for (const input of ['', 'English only', '中文'.repeat(30), '<think>未完成思考',
  '第一句。第二句。', '第一句。第二句', '战况：请小心。', '请小心（提醒）。',
  '# 战况\n请留意小地图。', '{"text":"请留意小地图"}',
  '中路敌人消失，请小心。', '敌人正在转线。', '敌人正在向中路支援。']) {
  assert.equal(normalizeBroadcast(input), BROADCAST_FALLBACK, input);
}
for (const input of [...valid, '中文'.repeat(30), '第一句。第二句。']) {
  assert.ok(Array.from(normalizeBroadcast(input)).length <= MAX_BROADCAST_CHARACTERS);
}
console.log('PASS: short sentence, thinking/format rejection, temporal claims, safe fallback');
