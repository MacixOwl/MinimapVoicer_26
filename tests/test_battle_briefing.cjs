const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const filename = path.join(__dirname, '../entry/src/main/ets/demo/BattleBriefing.ets');
const source = fs.readFileSync(filename, 'utf8');
const javascript = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
} }).outputText;
const sandbox = { exports: {} };
vm.runInNewContext(javascript, sandbox, { filename });
const { spokenBriefing, savedSpeechRate, BattleBriefingGate } = sandbox.exports;

assert.equal(spokenBriefing('下路2人靠近,先后撤!'), '下路二人靠近，先后撤。');
assert.equal(spokenBriefing(' 中路有人聚集； 留意河道。 '), '中路有人聚集，留意河道。');
assert.equal(spokenBriefing('下路敌人抱团，先往塔下靠。'), '下路敌人抱团，先往塔下靠。');
assert.equal(savedSpeechRate(1.18), 1.18);
for (const invalid of [NaN, Infinity, 10, -1, '1.18', undefined]) assert.equal(savedSpeechRate(invalid), 1.08);
const gate = new BattleBriefingGate();
const text = '下路敌人抱团，先往塔下靠。';
assert.equal(gate.shouldSpeak('小地图暂无明确动向。', 1000), false);
assert.equal(gate.shouldSpeak('画面不清，暂不判断。', 1000), false);
assert.equal(gate.shouldSpeak(text, 1000), true);
assert.equal(gate.shouldSpeak(text, 1001), true, 'failed or cancelled synthesis must not suppress a retry');
gate.didSpeak(text, 1001);
assert.equal(gate.shouldSpeak(text, 2000), false);
assert.equal(gate.shouldSpeak('中路敌人聚集，先保持距离。', 2000), true);
assert.equal(gate.shouldSpeak(text, 21000), false);
assert.equal(gate.shouldSpeak(text, 21001), true);
gate.didSpeak(text, 22000);
assert.equal(gate.shouldSpeak(text, 21000), true, 'clock rollback must not mute reminders');
gate.didSpeak(text, 22000);
gate.reset();
assert.equal(gate.shouldSpeak(text, 22001), true);
console.log('PASS: spoken punctuation/numerals, persisted speech rates, quiet observations, repeat cooldown, retry, clock rollback and reset');
