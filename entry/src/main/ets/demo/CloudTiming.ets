export const CLOUD_FRAME_MAX_AGE_MS: number = 30000;
export const LIVE_FRAME_MAX_AGE_MS: number = 8000;
export const LIVE_CAPTURE_INTERVAL_MS: number = 1000;

export class CloudFrameExpiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CloudFrameExpiredError';
  }
}

export function assertCloudFrameFresh(capturedAt: number,
  maxAgeMs: number = CLOUD_FRAME_MAX_AGE_MS): void {
  const age = Date.now() - capturedAt;
  if (!Number.isFinite(capturedAt) || age < -2000 || age > maxAgeMs) {
    throw new CloudFrameExpiredError(`截图超过${maxAgeMs / 1000}秒有效期或时间无效，跳过过期战况`);
  }
}

export function liveRequestBudgetMs(capturedAt: number): number {
  assertCloudFrameFresh(capturedAt, LIVE_FRAME_MAX_AGE_MS);
  const remaining = LIVE_FRAME_MAX_AGE_MS - Math.max(0, Date.now() - capturedAt) - 1000;
  if (remaining <= 0) throw new CloudFrameExpiredError('截图已接近过期，等待最新画面');
  return Math.min(6000, remaining);
}
