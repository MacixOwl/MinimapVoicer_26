import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import hash from '@ohos.file.hash';
import util from '@ohos.util';
import phonetts from 'libphonetts.so';
import { DEFAULT_SPEECH_RATE, savedSpeechRate } from './BattleBriefing';

interface SpeechFile {
  filename: string;
  size: number;
  sha256: string;
}
interface SpeechManifest {
  files: SpeechFile[];
}

export class LocalNeuralSpeech {
  private static preparing: Promise<void> | undefined;

  static async prepare(context: common.UIAbilityContext): Promise<void> {
    if (!LocalNeuralSpeech.preparing) {
      LocalNeuralSpeech.preparing = LocalNeuralSpeech.extractAndLoad(context).catch((error: Error) => {
        LocalNeuralSpeech.preparing = undefined;
        throw error;
      });
    }
    return LocalNeuralSpeech.preparing;
  }

  private static async extractAndLoad(context: common.UIAbilityContext): Promise<void> {
    const directory = `${context.filesDir}/local-neural-tts`;
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    const bytes = await context.resourceManager.getRawFileContent('local-tts.json');
    const manifest = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(bytes)) as SpeechManifest;
    for (const file of manifest.files) {
      if (!/^[a-zA-Z0-9_.-]+$/.test(file.filename)) throw new Error('内置语音资源路径错误');
      const path = `${directory}/${file.filename}`;
      const existing = fs.accessSync(path) && fs.statSync(path).size === file.size;
      if (existing && (await hash.hash(path, 'sha256')).toLowerCase() === file.sha256) continue;
      const content = await context.resourceManager.getRawFileContent(`local-tts/${file.filename}`);
      if (content.byteLength !== file.size) throw new Error('内置语音资源体积不匹配');
      const partial = `${path}.part`;
      const target = fs.openSync(partial, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const buffer = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
        if (fs.writeSync(target.fd, buffer) !== buffer.byteLength) throw new Error('写入本机语音资源失败');
      } finally {
        fs.closeSync(target);
      }
      if ((await hash.hash(partial, 'sha256')).toLowerCase() !== file.sha256) {
        fs.unlinkSync(partial);
        throw new Error('内置语音资源 SHA256 校验失败');
      }
      if (fs.accessSync(path)) fs.unlinkSync(path);
      fs.renameSync(partial, path);
    }
    await phonetts.initialize(directory);
  }

  static async synthesize(context: common.UIAbilityContext, text: string,
    rate: number = DEFAULT_SPEECH_RATE): Promise<ArrayBuffer> {
    await LocalNeuralSpeech.prepare(context);
    return phonetts.synthesize(text, savedSpeechRate(rate));
  }

  static async release(): Promise<void> {
    try {
      await LocalNeuralSpeech.preparing;
    } catch (_) {}
    await phonetts.release();
    LocalNeuralSpeech.preparing = undefined;
  }
}
