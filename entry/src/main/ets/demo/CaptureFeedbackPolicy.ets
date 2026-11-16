export const CAPTURE_FEEDBACK_DURATION_MS: number = 1500;
export const CAPTURE_FEEDBACK_MIN_GAP_MS: number = 2000;
export const CAPTURE_FEEDBACK_MAX_AGE_MS: number = 3000;

export interface FeedbackFrame {
  state: string;
  authorized: boolean;
  privateScene: boolean;
  frames: number;
  frameId: string;
  capturedAt: number;
}

export class CaptureFeedbackGate {
  private lastId: string = '';
  private lastNotice: number = -Infinity;

  reset(baseline: string = ''): void {
    this.lastId = baseline;
    this.lastNotice = -Infinity;
  }

  inspect(frame: FeedbackFrame, enabled: boolean, now: number): string {
    if (!frame.frameId || frame.frameId === this.lastId) return '';
    this.lastId = frame.frameId;
    if (!enabled || !frame.authorized || frame.privateScene || frame.state !== 'capturing' ||
        frame.frames <= 0 || now < frame.capturedAt ||
        now - frame.capturedAt > CAPTURE_FEEDBACK_MAX_AGE_MS ||
        now - this.lastNotice < CAPTURE_FEEDBACK_MIN_GAP_MS) return '';
    this.lastNotice = now;
    return `已截图 · 第 ${frame.frames} 帧`;
  }
}
