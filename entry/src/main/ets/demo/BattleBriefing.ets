export const DEFAULT_SPEECH_RATE: number = 1.08;
export const SPEECH_PREVIEW: string = '下路敌人抱团，先往塔下靠。';

export function savedSpeechRate(value: number): number {
  return [1.0, 1.08, 1.18].indexOf(value) >= 0 ? value : DEFAULT_SPEECH_RATE;
}

export function spokenBriefing(text: string): string {
  let result = text.trim().replace(/[,;；:：、]+/g, '，').replace(/[.!！?？]+/g, '。')
    .replace(/\s+/g, '').replace(/，+/g, '，').replace(/。+/g, '。')
    .replace(/^，|，(?=。)|[，。]+$/g, '');
  const numerals: string[] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
  result = result.replace(/\d+(?=人|名|个)/g, (digits: string): string => {
    const count = Number(digits);
    return count <= 10 ? numerals[count] : digits;
  });
  return result + (result.length < 32 ? '。' : '');
}

export function quietBriefing(text: string): boolean {
  const key = text.replace(/[，。\s]/g, '');
  return ['小地图暂无明确动向', '画面不清暂不判断'].indexOf(key) >= 0;
}

interface SpokenReminder {
  text: string;
  at: number;
}

export class BattleBriefingGate {
  private recent: SpokenReminder[] = [];

  reset(): void {
    this.recent = [];
  }

  shouldSpeak(text: string, now: number): boolean {
    if (quietBriefing(text)) return false;
    this.recent = this.recent.filter((item: SpokenReminder) => now >= item.at && now - item.at < 20000);
    return !this.recent.some((item: SpokenReminder) => item.text === text);
  }

  didSpeak(text: string, now: number): void {
    this.recent.push({ text: text, at: now });
    if (this.recent.length > 20) this.recent.shift();
  }
}
