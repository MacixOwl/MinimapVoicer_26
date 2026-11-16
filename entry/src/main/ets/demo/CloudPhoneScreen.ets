import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import phonecapture from 'libphonecapture.so';
import { DEFAULT_CAPTURE_INTERVAL_SECONDS } from './CaptureInterval';
import { PhoneFrame, ScreenStatus } from './PhoneScreen';

export interface CaptureCanvas {
  width: number;
  height: number;
}

export function cloudCaptureCanvas(width: number, height: number): CaptureCanvas {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width < 64 || height < 64) {
    throw new Error('无法读取设备屏幕尺寸');
  }
  const scale = Math.min(1, 1920 / Math.max(width, height));
  return { width: Math.max(64, Math.floor(width * scale / 2) * 2),
    height: Math.max(64, Math.floor(height * scale / 2) * 2) };
}

export class CloudPhoneScreen {
  static async status(): Promise<ScreenStatus> {
    return JSON.parse(await phonecapture.screenStatus()) as ScreenStatus;
  }

  static async start(context: common.UIAbilityContext, origin: string = '',
    intervalMs: number = DEFAULT_CAPTURE_INTERVAL_SECONDS * 1000): Promise<ScreenStatus> {
    if (origin) throw new Error('云端模式不启用原生截图上传');
    const screen = display.getDefaultDisplaySync();
    const canvas = cloudCaptureCanvas(screen.width, screen.height);
    return JSON.parse(await phonecapture.startScreen(context.cacheDir, '', intervalMs,
      canvas.width, canvas.height)) as ScreenStatus;
  }

  static async stop(): Promise<void> {
    await phonecapture.stopScreen();
  }

  static async read(after: string): Promise<PhoneFrame | undefined> {
    return phonecapture.readScreen(after);
  }
}
