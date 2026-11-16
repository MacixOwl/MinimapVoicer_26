// Real temporary files and SHA256, with API9 FileIO adapted to Node.
// This verifies storage semantics, not a HarmonyOS document provider or phone.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const ts = require('typescript');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gamevoice-model-storage-'));
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const files = [
  {filename: 'model.gguf', data: crypto.randomBytes(2 * 1048576 + 13)},
  {filename: 'mmproj.gguf', data: crypto.randomBytes(31007)}
];
const model = {id: 'test-vlm', model_path: 'test-model',
  files: files.map(file => ({filename: file.filename, size: file.data.length, checksum: sha(file.data)}))};
const active = path.join(root, 'models', model.model_path);
const staging = active + '.importing';
const previous = active + '.previous';
const exported = path.join(root, 'user-documents.gvb');
const descriptors = new Map();
let maxRead = 0;
let failWrite = false;
let failPublish = false;
let reads = 0;
const io = {
  OpenMode: {READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
    CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC},
  accessSync: file => fs.existsSync(file),
  mkdirSync: file => fs.mkdirSync(file),
  statSync: file => typeof file === 'number' ? fs.fstatSync(file) : fs.statSync(file),
  unlinkSync: file => fs.unlinkSync(file),
  rmdirSync: file => fs.rmdirSync(file),
  renameSync: (source, target) => {
    if (failPublish && path.resolve(source) === staging && path.resolve(target) === active) {
      failPublish = false;
      throw new Error('simulated publication failure');
    }
    fs.renameSync(source, target);
  },
  openSync: (file, mode) => {
    const fd = fs.openSync(file, mode & ~fs.constants.O_TRUNC);
    if (mode & fs.constants.O_TRUNC) fs.ftruncateSync(fd, 0);
    descriptors.set(fd, path.resolve(file));
    return {fd};
  },
  closeSync: file => {
    fs.closeSync(file.fd);
    descriptors.delete(file.fd);
  },
  read: async (fd, data, options) => {
    reads++;
    maxRead = Math.max(maxRead, data.byteLength);
    // Exercise short reads as well as explicit file offsets.
    return fs.readSync(fd, Buffer.from(data), 0, Math.min(options.length, 77777), options.offset);
  },
  write: async (fd, data, options) => {
    if (failWrite && descriptors.get(fd).startsWith(staging)) throw new Error('simulated no space');
    // Exercise short writes; an offset into the file is not a buffer offset.
    return fs.writeSync(fd, Buffer.from(data), 0, Math.min(options.length, 32749), options.offset);
  },
  fsync: async fd => fs.fsyncSync(fd)
};
const mocks = {
  '@ohos.file.fs': {default: io},
  '@ohos.file.hash': {default: {hash: async file => sha(fs.readFileSync(file))}},
  '@ohos.util': {default: {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: class { decodeWithStream(data) { return new TextDecoder().decode(data); } }
  }}
};
const cache = {};
function load(name) {
  if (cache[name]) return cache[name];
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/demo', name + '.ets'), 'utf8');
  const compiled = ts.transpileModule(source, {compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2017
  }}).outputText;
  const module = {exports: {}};
  new Function('require', 'module', 'exports', compiled)(key => {
    if (key.startsWith('./')) return load(key.slice(2));
    if (mocks[key]) return mocks[key];
    throw new Error(`Unexpected platform dependency ${key}`);
  }, module, module.exports);
  return cache[name] = module.exports;
}
const codec = load('ModelBackup');
const {ModelStorage} = load('ModelStorage');
const context = {filesDir: root, resourceManager: {
  getRawFileContent: async () => new TextEncoder().encode(JSON.stringify({models: [model]}))
}};
const fresh = () => new ModelStorage(context);
function seed(directory = active) {
  fs.mkdirSync(directory, {recursive: true});
  for (const file of files) fs.writeFileSync(path.join(directory, file.filename), file.data);
}
function unchanged() {
  for (const file of files) assert.deepEqual(fs.readFileSync(path.join(active, file.filename)), file.data);
  assert.equal(descriptors.size, 0, 'all files must be closed');
}
const malformed = path.join(root, 'bad-backup.gvb');
async function rejectImport(data, expected) {
  fs.writeFileSync(malformed, data);
  await assert.rejects(fresh().importBackup(malformed, () => {}), expected);
  unchanged();
  assert.equal(fs.existsSync(staging), false, 'failed restore must clean its staging directory');
}
async function main() {
  await fresh().recover();
  assert.equal((await fresh().status()).complete, false);
  seed();
  assert.equal((await fresh().status()).complete, true);
  fs.writeFileSync(exported, '');
  await fresh().exportBackup(exported, () => {});
  const backup = fs.readFileSync(exported);
  const length = codec.backupHeaderLength(backup.subarray(0, 12).buffer.slice(
    backup.byteOffset, backup.byteOffset + 12));
  const payloadOffset = 12 + length;
  assert.equal(backup.length, payloadOffset + files.reduce((sum, file) => sum + file.data.length, 0));
  assert.ok(reads > 20);
  assert.ok(maxRead <= codec.BACKUP_CHUNK_BYTES, 'model contents must be streamed');
  unchanged();

  await fresh().deleteDownloaded();
  assert.equal(fs.existsSync(exported), true, 'deletion must preserve user backup');
  assert.equal((await fresh().status()).complete, false);
  await fresh().importBackup(exported, () => {});
  unchanged();
  assert.equal((await fresh().status()).complete, true);
  assert.equal(fs.existsSync(previous), false);

  await rejectImport(Buffer.from('not a model archive'), /备份/);
  await rejectImport(backup.subarray(0, backup.length - 1), /体积/);
  await rejectImport(Buffer.concat([backup, Buffer.from([0])]), /体积/);
  const damaged = Buffer.from(backup);
  damaged[payloadOffset + 3] ^= 0xff;
  await rejectImport(damaged, /SHA256/);
  const excessive = Buffer.from(backup);
  excessive.writeUInt32LE(10000000, 8);
  await rejectImport(excessive, /备份头/);
  for (const altered of [
    {modelId: 'different-model', files: model.files},
    {modelId: model.id, files: []},
    {modelId: model.id, files: [{...model.files[0], filename: '../escape'}, model.files[1]]},
    {modelId: model.id, files: [{...model.files[0], checksum: '0'.repeat(64)}, model.files[1]]}
  ]) {
    const header = Buffer.from(codec.encodeBackupHeader(altered));
    await rejectImport(Buffer.concat([header, backup.subarray(payloadOffset)]), /不一致/);
  }
  assert.equal(fs.existsSync(path.join(root, 'escape')), false);

  failWrite = true;
  await assert.rejects(fresh().importBackup(exported, () => {}), /no space/);
  failWrite = false;
  unchanged();
  assert.equal(fs.existsSync(staging), false);

  failPublish = true;
  await assert.rejects(fresh().importBackup(exported, () => {}), /publication failure/);
  unchanged();
  assert.equal(fs.existsSync(previous), false, 'rename failure must roll back the old directory');

  const cancelled = fresh();
  await assert.rejects(cancelled.importBackup(exported, () => cancelled.cancel()), /取消/);
  unchanged();
  assert.equal(fs.existsSync(staging), false);

  // Recover the interrupted old-directory -> previous-directory step.
  fs.renameSync(active, previous);
  seed(staging);
  await fresh().recover();
  unchanged();
  assert.equal(fs.existsSync(staging), false);
  assert.equal(fs.existsSync(previous), false);
  seed(previous);
  seed(staging);
  await fresh().recover();
  unchanged();
  assert.equal(fs.existsSync(staging), false);
  assert.equal(fs.existsSync(previous), false);

  // Export must reject broken source models, even if file size is unchanged.
  const broken = Buffer.from(files[0].data);
  broken[0] ^= 0xff;
  fs.writeFileSync(path.join(active, files[0].filename), broken);
  await assert.rejects(fresh().exportBackup(exported, () => {}), /校验失败/);
  assert.deepEqual(fs.readFileSync(exported), backup, 'failed source validation must not truncate the backup');
  seed();
  fs.writeFileSync(path.join(active, 'model.gguf.part'), 'incomplete download');
  assert.equal((await fresh().status()).bytes, files.reduce((sum, file) => sum + file.data.length, 0) + 19);
  await fresh().deleteDownloaded();
  assert.equal(fs.existsSync(active), false);
  assert.equal(fs.existsSync(exported), true);
  assert.equal(descriptors.size, 0);
  console.log('PASS: streamed backup/restore, SHA256, bad headers/paths/versions, truncation, short I/O, ' +
    'no-space cleanup, cancellation, rollback, crash recovery and private-only deletion');
}
main().finally(() => fs.rmSync(root, {recursive: true, force: true})).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
