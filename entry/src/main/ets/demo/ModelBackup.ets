import util from '@ohos.util';

export interface BackupModelFile {
  filename: string;
  size: number;
  checksum: string;
}

export interface BackupModel {
  modelId: string;
  files: BackupModelFile[];
}

export interface BackupReader {
  read(offset: number, length: number): Promise<ArrayBuffer>;
}

export interface BackupWriter {
  write(offset: number, data: ArrayBuffer): Promise<void>;
}

const MAGIC: number[] = [83, 71, 86, 66, 75, 48, 48, 49]; // SGVBK001
export const BACKUP_PREFIX_BYTES = 12;
export const BACKUP_CHUNK_BYTES = 1048576;
const MAX_HEADER_BYTES = 8192;

export function encodeBackupHeader(model: BackupModel): ArrayBuffer {
  const json = new util.TextEncoder().encodeInto(JSON.stringify(model));
  if (json.byteLength === 0 || json.byteLength > MAX_HEADER_BYTES) {
    throw new Error('模型备份清单过大');
  }
  const result = new ArrayBuffer(BACKUP_PREFIX_BYTES + json.byteLength);
  const bytes = new Uint8Array(result);
  bytes.set(MAGIC);
  new DataView(result).setUint32(8, json.byteLength, true);
  bytes.set(json, BACKUP_PREFIX_BYTES);
  return result;
}

export function backupHeaderLength(prefix: ArrayBuffer): number {
  if (prefix.byteLength !== BACKUP_PREFIX_BYTES ||
    MAGIC.some((value: number, index: number) => new Uint8Array(prefix)[index] !== value)) {
    throw new Error('不是本应用的模型备份文件（.gvb）');
  }
  const size = new DataView(prefix).getUint32(8, true);
  if (size === 0 || size > MAX_HEADER_BYTES) throw new Error('模型备份头损坏');
  return size;
}

export function checkBackupHeader(header: ArrayBuffer, expected: BackupModel): void {
  let actual: BackupModel;
  try {
    actual = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(header))) as BackupModel;
  } catch (_) {
    throw new Error('模型备份清单损坏');
  }
  if (!actual || actual.modelId !== expected.modelId || !Array.isArray(actual.files) ||
    actual.files.length !== expected.files.length) {
    throw new Error('备份与当前应用所需的模型版本不一致');
  }
  for (let i = 0; i < expected.files.length; ++i) {
    const file = actual.files[i];
    const known = expected.files[i];
    if (!file || file.filename !== known.filename || file.size !== known.size ||
      file.checksum !== known.checksum) {
      throw new Error('备份清单与内置模型清单不一致');
    }
  }
}

export async function readBackupBytes(reader: BackupReader, offset: number, length: number,
  checkCancelled: () => void): Promise<ArrayBuffer> {
  const result = new Uint8Array(length);
  let received = 0;
  while (received < length) {
    checkCancelled();
    const part = await reader.read(offset + received, length - received);
    if (part.byteLength === 0 || part.byteLength > length - received) {
      throw new Error('模型备份读取不完整');
    }
    result.set(new Uint8Array(part), received);
    received += part.byteLength;
  }
  return result.buffer;
}

export async function copyBackupBytes(reader: BackupReader, writer: BackupWriter,
  sourceOffset: number, targetOffset: number, length: number,
  progress: (copied: number) => void, checkCancelled: () => void): Promise<void> {
  let copied = 0;
  while (copied < length) {
    checkCancelled();
    const size = Math.min(BACKUP_CHUNK_BYTES, length - copied);
    const data = await readBackupBytes(reader, sourceOffset + copied, size, checkCancelled);
    checkCancelled();
    await writer.write(targetOffset + copied, data);
    copied += size;
    progress(copied);
  }
}
