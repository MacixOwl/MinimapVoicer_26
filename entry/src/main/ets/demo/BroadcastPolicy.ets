export const MAX_BROADCAST_CHARACTERS: number = 25;
export const BROADCAST_FALLBACK: string = '画面信息不足，注意小地图。';
export const TEST_BROADCAST: string = '这是一条测试播报。';

// The prompt cannot guarantee compliance. Validate before display and speech.
// Fall back rather than cutting a long sentence in the middle of its meaning.
export function normalizeBroadcast(raw: string): string {
  if (typeof raw !== 'string' || raw.length > 4096) return BROADCAST_FALLBACK;
  let text = raw.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  if (/<\/?think\b/i.test(text)) return BROADCAST_FALLBACK;
  text = text.replace(/^(播报|提醒|解说)[：:]\s*/, '').replace(/^[“"]|[”"]$/g, '').trim();
  if (!text || !/[\u3400-\u9fff]/.test(text) ||
      /[\r\n#*_`|<>{}\[\]():：;；（）]/.test(text) || /https?:\/\//i.test(text) ||
      Array.from(text).length > MAX_BROADCAST_CHARACTERS ||
      (text.match(/[。！？!?]/g) ?? []).length > 1) {
    return BROADCAST_FALLBACK;
  }
  const sentenceEnd = text.search(/[。！？!?]/);
  if (sentenceEnd >= 0 && sentenceEnd !== text.length - 1) return BROADCAST_FALLBACK;
  // A single frame cannot establish disappearance or a rotation over time.
  // This blocks common unsupported claims, but cannot establish visual truth.
  if (/消失|失踪|转线|转路|(?:前往|正在|即将).{0,6}支援/.test(text)) {
    return BROADCAST_FALLBACK;
  }
  return text;
}
