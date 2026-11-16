import common from '@ohos.app.ability.common';

export const NATIVE_SCREEN_ENABLED: boolean = false;

export class Frame {
  public bytes: Uint8Array;
  public mime: string;

  constructor(bytes: Uint8Array, mime: string) {
    this.bytes = bytes;
    this.mime = mime;
  }
}

export async function captureFrame(context: common.UIAbilityContext, nativeScreen: boolean): Promise<Frame> {
  if (nativeScreen) {
    throw new Error('该构建未启用受限的原生截屏接口，请用样例图或 USB 实时模式。');
  }
  const bytes = await context.resourceManager.getRawFileContent('sample.png');
  return new Frame(bytes, 'image/png');
}
