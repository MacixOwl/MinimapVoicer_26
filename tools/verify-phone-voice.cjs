const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const executable = process.argv[2] || path.join(root,
  'build/phone-tts-modern/adapter-windows/Release/phone_tts.exe');
const modelDirectory = path.join(root, 'entry/src/main/resources/rawfile/local-tts');
const outputDirectory = path.join(root, 'artifacts/voice-preview');
fs.mkdirSync(outputDirectory, { recursive: true });
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const cases = [
  { name: 'clear', text: '下路敌人抱团，先往塔下靠。', rate: 1.0 },
  { name: 'balanced', text: '下路敌人抱团，先往塔下靠。', rate: 1.08 },
  { name: 'brisk', text: '下路敌人抱团，先往塔下靠。', rate: 1.18 },
  { name: 'support', text: '中路被包围，附近队友帮忙接应。', rate: 1.08 },
  { name: 'short-location', text: '下路，敌人抱团，先退回塔下。', rate: 1.08 },
  { name: 'neutral', text: '中央多人聚集，留意这片区域。', rate: 1.08 }
];
const report = { tested_at: new Date().toISOString(), platform: process.platform,
  adapter_sha256: hash(fs.readFileSync(executable)),
  model_sha256: hash(fs.readFileSync(path.join(modelDirectory, 'model.onnx'))),
  phone_tested: false, human_listening_verified: false, asr_verified: false, cases: [] };
for (const item of cases) {
  const input = path.join(outputDirectory, item.name + '.txt');
  const output = path.join(outputDirectory, item.name + '.wav');
  fs.writeFileSync(input, item.text, 'utf8');
  const result = spawnSync(executable,
    [modelDirectory, '--text-file', input, output, '--rate', String(item.rate)],
    { encoding: 'utf8', timeout: 60000, windowsHide: true });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);
  const wav = fs.readFileSync(output);
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.toString('ascii', 8, 12), 'WAVE');
  assert.equal(wav.readUInt16LE(20), 1);
  assert.equal(wav.readUInt16LE(22), 1);
  const sampleRate = wav.readUInt32LE(24);
  assert.equal(sampleRate, 22050);
  assert.equal(wav.readUInt16LE(34), 16);
  assert.equal(wav.readUInt32LE(40), wav.length - 44);
  const sampleCount = (wav.length - 44) / 2;
  let peak = 0, power = 0, first = -1, last = -1, silentRun = 0, longestPause = 0;
  for (let index = 0; index < sampleCount; index++) {
    const sample = Math.abs(wav.readInt16LE(44 + index * 2));
    peak = Math.max(peak, sample);
    power += sample * sample;
    if (sample > 90) {
      if (first < 0) first = index;
      else longestPause = Math.max(longestPause, silentRun);
      last = index;
      silentRun = 0;
    } else if (first >= 0) silentRun++;
  }
  const seconds = sampleCount / sampleRate;
  assert.ok(seconds > 0.5 && seconds <= 15, 'bounded, nonempty audio');
  assert.ok(peak > 1000 && peak < 32767, 'audible signal without PCM clipping');
  assert.ok(first / sampleRate < 0.15 && (sampleCount - last) / sampleRate < 0.15,
    'no long leading or trailing dead air');
  assert.ok(longestPause / sampleRate >= 0.14, 'clauses have an explicit short pause');
  if (item.name === 'short-location') {
    assert.ok(longestPause / sampleRate < 0.35, 'a two-character location must not create a long isolated pause');
  }
  const details = { ...item, sha256: hash(wav), bytes: wav.length,
    sample_rate: sampleRate, seconds: Number(seconds.toFixed(3)), peak,
    rms: Number((Math.sqrt(power / sampleCount) / 32768).toFixed(4)),
    longest_pause_ms: Math.round(longestPause / sampleRate * 1000), adapter_metrics: result.stdout.trim() };
  report.cases.push(details);
  console.log(JSON.stringify(details));
}
assert.ok(report.cases[2].seconds < report.cases[0].seconds,
  'changing the selected speed must affect real model output duration');
for (const rejected of [{ name: 'invalid-rate', text: '中路有人聚集。', rate: 'NaN' },
  { name: 'punctuation-only', text: '，，。。', rate: '1.08' }]) {
  const input = path.join(outputDirectory, rejected.name + '.txt');
  fs.writeFileSync(input, rejected.text, 'utf8');
  const result = spawnSync(executable, [modelDirectory, '--text-file', input,
    path.join(outputDirectory, rejected.name + '.wav'), '--rate', rejected.rate],
    { encoding: 'utf8', timeout: 60000, windowsHide: true });
  if (result.error) throw result.error;
  assert.equal(result.status, 1, 'invalid speech must fail cleanly');
}
fs.writeFileSync(path.join(outputDirectory, 'verification.json'), JSON.stringify(report, null, 2) + '\n');
console.log('PASS: actual shared C++ adapter, six real Matcha/Vocos WAVs, pace changes, clause pauses, PCM limits and rejected invalid inputs');
