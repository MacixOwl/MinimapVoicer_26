import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import hash from '@ohos.file.hash';
import util from '@ohos.util';
import {
  BackupModelFile, BackupModel, BackupReader, BackupWriter, BACKUP_PREFIX_BYTES,
  encodeBackupHeader, backupHeaderLength, checkBackupHeader, copyBackupBytes, readBackupBytes
} from './ModelBackup';

interface StorageModel {
  id: string;
  model_path: string;
  files: BackupModelFile[];
}

interface StorageManifest {
  models: StorageModel[];
}

interface ModelPaths {
  model: StorageModel;
  directory: string;
  staging: string;
  previous: string;
}

export interface ModelStorageStatus {
  text: string;
  complete: boolean;
  bytes: number;
}

// Explicit file offsets are used for API9 FileIO; short writes are retried.
class ModelFileIO implements BackupReader, BackupWriter {
  private fd: number;

  constructor(fd: number) {
    this.fd = fd;
  }

  async read(offset: number, length: number): Promise<ArrayBuffer> {
    const data = new ArrayBuffer(length);
    const size = await fs.read(this.fd, data, { offset: offset, length: length });
    if (size < 0 || size > length) throw new Error('模型文件读取失败');
    return size === length ? data : data.slice(0, size);
  }

  async write(offset: number, data: ArrayBuffer): Promise<void> {
    let written = 0;
    while (written < data.byteLength) {
      const remaining = written === 0 ? data : data.slice(written);
      const size = await fs.write(this.fd, remaining, { offset: offset + written, length: remaining.byteLength });
      if (size <= 0 || size > remaining.byteLength) throw new Error('模型文件写入不完整');
      written += size;
    }
  }
}

export class ModelStorage {
  private cancelled: boolean = false;

  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  cancel(): void {
    this.cancelled = true;
  }

  private checkCancelled(): void {
    if (this.cancelled) throw new Error('已取消模型文件操作');
  }

  private async paths(): Promise<ModelPaths> {
    const raw = await this.context.resourceManager.getRawFileContent('models.json');
    const manifest = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(raw)) as StorageManifest;
    const model = manifest.models[0];
    if (!model || !/^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$/.test(model.model_path) ||
      !Array.isArray(model.files) || model.files.length === 0 || model.files.length > 8) {
      throw new Error('内置模型目录清单错误');
    }
    const names: string[] = [];
    for (const file of model.files) {
      if (!/^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$/.test(file.filename) ||
        !Number.isSafeInteger(file.size) || file.size <= 0 || !/^[a-f0-9]{64}$/.test(file.checksum) ||
        names.indexOf(file.filename) !== -1) {
        throw new Error('内置模型文件清单错误');
      }
      names.push(file.filename);
    }
    const parent = `${this.context.filesDir}/models`;
    if (!fs.accessSync(parent)) fs.mkdirSync(parent);
    const directory = `${parent}/${model.model_path}`;
    return { model: model, directory: directory, staging: `${directory}.importing`,
      previous: `${directory}.previous` };
  }

  private removeDirectory(directory: string, model: StorageModel): void {
    if (!fs.accessSync(directory)) return;
    // Only remove files named by the trusted, bundled manifest.
    for (const file of model.files) {
      for (const suffix of ['', '.part']) {
        const path = `${directory}/${file.filename}${suffix}`;
        if (fs.accessSync(path)) fs.unlinkSync(path);
      }
    }
    fs.rmdirSync(directory);
  }

  // A killed process may leave a prepared import or the old model directory.
  // Restore the old directory if publication was interrupted.
  async recover(): Promise<void> {
    const paths = await this.paths();
    if (fs.accessSync(paths.previous)) {
      if (!fs.accessSync(paths.directory)) {
        fs.renameSync(paths.previous, paths.directory);
      } else {
        this.removeDirectory(paths.previous, paths.model);
      }
    }
    this.removeDirectory(paths.staging, paths.model);
  }

  async status(): Promise<ModelStorageStatus> {
    const paths = await this.paths();
    let bytes = 0;
    let complete = true;
    const lines: string[] = [];
    for (const file of paths.model.files) {
      const path = `${paths.directory}/${file.filename}`;
      const size = fs.accessSync(path) ? fs.statSync(path).size : 0;
      bytes += size;
      complete = complete && size === file.size;
      lines.push(`${file.filename}：${size === file.size ? '已存在' : '缺失或不完整'}`);
      const partial = `${path}.part`;
      if (fs.accessSync(partial)) bytes += fs.statSync(partial).size;
    }
    return {
      complete: complete,
      bytes: bytes,
      text: `已下载视觉模型占用 ${(bytes / 1048576).toFixed(1)} MiB。\n${lines.join('\n')}\n` +
        (complete ? '文件体积符合清单；备份、恢复及模型启动时另做 SHA256 校验。' :
          '可从备份恢复，或返回首页下载模型。')
    };
  }

  private backupModel(model: StorageModel): BackupModel {
    return { modelId: model.id, files: model.files };
  }

  async exportBackup(uri: string, progress: (text: string) => void): Promise<void> {
    const paths = await this.paths();
    for (const file of paths.model.files) {
      this.checkCancelled();
      const path = `${paths.directory}/${file.filename}`;
      progress(`校验 ${file.filename}……`);
      if (!fs.accessSync(path) || fs.statSync(path).size !== file.size ||
        (await hash.hash(path, 'sha256')).toLowerCase() !== file.checksum) {
        throw new Error('本机模型缺失或校验失败，请先在首页完成模型下载');
      }
    }
    this.checkCancelled();
    const output = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const writer = new ModelFileIO(output.fd);
      const header = encodeBackupHeader(this.backupModel(paths.model));
      await writer.write(0, header);
      let offset = header.byteLength;
      for (const file of paths.model.files) {
        this.checkCancelled();
        const input = fs.openSync(`${paths.directory}/${file.filename}`, fs.OpenMode.READ_ONLY);
        try {
          await copyBackupBytes(new ModelFileIO(input.fd), writer, 0, offset, file.size,
            (copied: number) => progress(`备份 ${file.filename}：${Math.floor(copied / 1048576)} MiB`),
            () => this.checkCancelled());
        } finally {
          fs.closeSync(input);
        }
        offset += file.size;
      }
      this.checkCancelled();
      await fs.fsync(output.fd);
      if (fs.statSync(output.fd).size !== offset) throw new Error('备份文件体积校验失败');
    } finally {
      fs.closeSync(output);
    }
  }

  async importBackup(uri: string, progress: (text: string) => void): Promise<void> {
    const paths = await this.paths();
    this.checkCancelled();
    const input = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const reader = new ModelFileIO(input.fd);
      const check = () => this.checkCancelled();
      const prefix = await readBackupBytes(reader, 0, BACKUP_PREFIX_BYTES, check);
      const length = backupHeaderLength(prefix);
      const header = await readBackupBytes(reader, BACKUP_PREFIX_BYTES, length, check);
      checkBackupHeader(header, this.backupModel(paths.model));
      let offset = BACKUP_PREFIX_BYTES + length;
      const expectedSize = offset + paths.model.files.reduce((total: number, file: BackupModelFile) =>
        total + file.size, 0);
      if (fs.statSync(input.fd).size !== expectedSize) throw new Error('模型备份体积不完整或含有额外数据');
      this.removeDirectory(paths.staging, paths.model);
      fs.mkdirSync(paths.staging);
      for (const file of paths.model.files) {
        check();
        const path = `${paths.staging}/${file.filename}`;
        const output = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          await copyBackupBytes(reader, new ModelFileIO(output.fd), offset, 0, file.size,
            (copied: number) => progress(`恢复 ${file.filename}：${Math.floor(copied / 1048576)} MiB`), check);
          await fs.fsync(output.fd);
        } finally {
          fs.closeSync(output);
        }
        check();
        progress(`校验恢复的 ${file.filename}……`);
        if ((await hash.hash(path, 'sha256')).toLowerCase() !== file.checksum) {
          throw new Error('备份模型 SHA256 校验失败，原有模型未替换');
        }
        offset += file.size;
      }
      check();
      // Publish only after every file was verified. Keep the old set for rollback.
      if (fs.accessSync(paths.previous)) throw new Error('存在未清理的恢复记录，请重新进入此页面');
      if (fs.accessSync(paths.directory)) fs.renameSync(paths.directory, paths.previous);
      try {
        fs.renameSync(paths.staging, paths.directory);
      } catch (error) {
        if (fs.accessSync(paths.previous)) fs.renameSync(paths.previous, paths.directory);
        throw error as Error;
      }
      try {
        this.removeDirectory(paths.previous, paths.model);
      } catch (_) {
        progress('模型已恢复，旧副本将在下次模型检查时清理。');
      }
    } finally {
      fs.closeSync(input);
      this.removeDirectory(paths.staging, paths.model);
    }
  }

  async deleteDownloaded(): Promise<void> {
    this.checkCancelled();
    const paths = await this.paths();
    this.removeDirectory(paths.directory, paths.model);
    this.removeDirectory(paths.staging, paths.model);
    this.removeDirectory(paths.previous, paths.model);
  }
}
