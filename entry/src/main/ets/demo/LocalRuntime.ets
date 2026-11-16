import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import request from '@ohos.request';
import gamevoice from 'libgamevoice.so';
import { ModelStorage } from './ModelStorage';
import { ROCKCHIP_MOCK_ONLY } from './DemoMode';

interface ModelFile {
  filename: string;
  size: number;
  checksum: string;
}
interface ModelInfo {
  id: string;
  base_url: string;
  model_path: string;
  files: ModelFile[];
}
interface ModelManifest {
  models: ModelInfo[];
}

async function rawText(context: common.UIAbilityContext, name: string): Promise<string> {
  const bytes = await context.resourceManager.getRawFileContent(name);
  return new util.TextDecoder('utf-8').decodeWithStream(bytes);
}

function mkdir(path: string): void {
  if (!fs.accessSync(path)) {
    fs.mkdirSync(path);
  }
}

export class LocalRuntime {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async download(progress: (text: string) => void, replace: boolean = false): Promise<void> {
    if (ROCKCHIP_MOCK_ONLY) throw new Error('当前版本已关闭视觉模型下载。');
    await new ModelStorage(this.context).recover();
    const manifest = JSON.parse(await rawText(this.context, 'models.json')) as ModelManifest;
    const model = manifest.models[0];
    const parent = `${this.context.filesDir}/models`;
    const dir = `${parent}/${model.model_path}`;
    mkdir(parent);
    mkdir(dir);
    for (const file of model.files) {
      const path = `${dir}/${file.filename}`;
      if (!replace && fs.accessSync(path) && fs.statSync(path).size === file.size) {
        progress(`${file.filename} 已存在，启动时校验 SHA256`);
        continue;
      }
      const partial = `${path}.part`;
      if (fs.accessSync(partial)) {
        fs.unlinkSync(partial);
      }
      progress(`开始下载 ${file.filename}`);
      const task = await request.downloadFile(this.context, {
        url: `${model.base_url}/${file.filename}`, filePath: partial
      });
      await new Promise<void>((resolve, reject) => {
        task.on('progress', (received: number, total: number) => {
          progress(`${file.filename} · ${Math.floor(received / 1048576)} / ${Math.ceil(file.size / 1048576)} MiB`);
        });
        task.on('complete', () => {
          try {
            if (!fs.accessSync(partial) || fs.statSync(partial).size !== file.size) {
              throw new Error(`下载体积不匹配：${file.filename}`);
            }
            if (fs.accessSync(path)) {
              fs.unlinkSync(path);
            }
            fs.renameSync(partial, path);
            resolve();
          } catch (error) {
            reject(error as Error);
          }
        });
        task.on('fail', (code: number) => reject(new Error(`模型下载失败 ${code}，可重新下载`)));
      });
    }
    progress('模型文件已就绪，启动时由 SmartServe 校验完整性。');
  }

  async start(peer: string): Promise<string> {
    if (ROCKCHIP_MOCK_ONLY && !/^https?:\/\/[^/\s?#@]+$/.test(peer)) {
      throw new Error('当前版本仅支持转发，请填写瑞芯微模拟服务地址。');
    }
    await new ModelStorage(this.context).recover();
    return gamevoice.start(this.context.filesDir, await rawText(this.context, 'models.json'), peer);
  }

  async release(): Promise<void> {
    await gamevoice.stop();
  }

  async speech(text: string): Promise<ArrayBuffer> {
    const parent = `${this.context.filesDir}/tts`;
    const data = `${parent}/espeak-ng-data`;
    mkdir(parent);
    mkdir(data);
    const names = JSON.parse(await rawText(this.context, 'tts-manifest.json')) as string[];
    for (const name of names) {
      const pieces = name.split('/');
      let path = data;
      for (let i = 0; i < pieces.length - 1; ++i) {
        path += `/${pieces[i]}`;
        mkdir(path);
      }
      const target = `${data}/${name}`;
      const bytes = await this.context.resourceManager.getRawFileContent(`tts/${name}`);
      if (fs.accessSync(target) && fs.statSync(target).size === bytes.byteLength) {
        continue;
      }
      const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        if (fs.writeSync(file.fd, buffer) !== bytes.byteLength) {
          throw new Error('本地语音资源写入不完整');
        }
      } finally {
        fs.closeSync(file);
      }
    }
    return gamevoice.synthesize(text, parent);
  }
}
