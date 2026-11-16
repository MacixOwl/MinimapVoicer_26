import common from '@ohos.app.ability.common';
import gamevoice from 'libgamevoice.so';
import { DEFAULT_CAPTURE_INTERVAL_SECONDS } from './CaptureInterval';
import { FeedbackFrame } from './CaptureFeedbackPolicy';

export interface ScreenStatus extends FeedbackFrame {
  supported: boolean;
  requiredApi: number;
  missing: string[];
  state: string;
  authorized: boolean;
  privateScene: boolean;
  intervalMs: number;
  frames: number;
  uploads: number;
  width: number;
  height: number;
  requestedWidth?: number;
  requestedHeight?: number;
  canvasRotation?: boolean;
  followRotation?: boolean;
  frameId: string;
  capturedAt: number;
  error: string;
  uploadError: string;
  reply: string;
}

export interface PhoneFrame {
  bytes: ArrayBuffer;
  id: string;
  capturedAt: number;
}

export class PhoneScreen {
  static async status(): Promise<ScreenStatus> {
    return JSON.parse(await gamevoice.screenStatus()) as ScreenStatus;
  }

  static async start(context: common.UIAbilityContext, origin: string = '',
    intervalMs: number = DEFAULT_CAPTURE_INTERVAL_SECONDS * 1000): Promise<ScreenStatus> {
    return JSON.parse(await gamevoice.startScreen(context.cacheDir, origin, intervalMs)) as ScreenStatus;
  }

  static async stop(): Promise<void> {
    await gamevoice.stopScreen();
  }

  static async read(after: string): Promise<PhoneFrame | undefined> {
    return gamevoice.readScreen(after);
  }
}
