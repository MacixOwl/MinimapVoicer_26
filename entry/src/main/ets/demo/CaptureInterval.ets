export const DEFAULT_CAPTURE_INTERVAL_SECONDS: number = 10;
export const MIN_CAPTURE_INTERVAL_SECONDS: number = 1;
export const MAX_CAPTURE_INTERVAL_SECONDS: number = 300;

export function parseCaptureIntervalMs(value: string): number {
  const text = value.trim();
  const seconds = Number(text);
  if (!/^\d+$/.test(text) || !Number.isInteger(seconds) ||
      seconds < MIN_CAPTURE_INTERVAL_SECONDS || seconds > MAX_CAPTURE_INTERVAL_SECONDS) {
    throw new Error('截图间隔请输入 1～300 的整数秒');
  }
  return seconds * 1000;
}
