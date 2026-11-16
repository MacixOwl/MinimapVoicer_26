// Structured observations, not previous model captions, form temporal state.
// Counts are still model predictions; this does not establish game truth.
export interface MapObservation {
  readable: boolean;
  confidence: number;
  cells: number[];
}

interface RawMapObservation {
  readable: boolean;
  confidence: number;
  cells: number[] | number[][];
}

export interface MapDecision {
  text: string;
  status: string;
}

export const MAP_MAX_AGE_MS: number = 15000;
const MAX_GAP_MS: number = 30000;
const COOLDOWN_MS: number = 15000;
const REPEAT_MS: number = 45000;
const REGIONS: string[] = ['左上', '上方', '右上', '左侧', '中央', '右侧', '左下', '下方', '右下'];

export function parseMapObservation(raw: string): MapObservation | undefined {
  if (typeof raw !== 'string' || raw.length > 4096) return undefined;
  try {
    // Small models sometimes wrap valid data in a complete JSON code block.
    // Accept this formatting only; never extract an arbitrary object from prose.
    const clean = raw.trim().replace(/^```(?:json)?\s*\n([\s\S]*?)\n```$/i, '$1').trim();
    const value = JSON.parse(clean) as RawMapObservation;
    let cells = value.cells as number[];
    if (value && Array.isArray(value.cells) && Array.isArray(value.cells[0])) {
      const rows = value.cells as number[][];
      if ((rows.length === 1 && rows[0].length === 9) ||
          (rows.length === 3 && rows.every((row: number[]) => Array.isArray(row) && row.length === 3))) {
        cells = ([] as number[]).concat(...rows);
      }
    }
    if (!value || typeof value.readable !== 'boolean' ||
        typeof value.confidence !== 'number' || !Number.isFinite(value.confidence) ||
        value.confidence < 0 || value.confidence > 1 ||
        !Array.isArray(cells) || cells.length !== 9 ||
        cells.some((n: number) => !Number.isInteger(n) || n < 0 || n > 5) ||
        cells.reduce((sum: number, n: number) => sum + n, 0) > 5) return undefined;
    return { readable: value.readable, confidence: value.confidence, cells: cells.slice() };
  } catch (_) {
    return undefined;
  }
}

export function parseMinimapRoi(raw: string): number[] {
  const values = raw.split(',').map((part: string) => Number(part.trim()));
  if (values.length !== 4 || raw.split(',').some((part: string) => !part.trim()) ||
      values.some((n: number) => !Number.isFinite(n)) ||
      values[0] < 0 || values[1] < 0 || values[2] <= 0 || values[3] <= 0 ||
      values[0] + values[2] > 1 || values[1] + values[3] > 1) {
    throw new Error('小地图范围须为 x,y,宽,高，取值 0～1 且不能超出画面');
  }
  return values;
}

export class MinimapTracker {
  private anchor: MapObservation | undefined;
  private lastTime: number = 0;
  private geometry: string = '';
  private pending: string = '';
  private confirmations: number = 0;
  private lastSpoken: number = -Infinity;
  private repeated: Map<string, number> = new Map();

  reset(): void {
    this.anchor = undefined;
    this.lastTime = 0;
    this.geometry = '';
    this.pending = '';
    this.confirmations = 0;
    this.lastSpoken = -Infinity;
    this.repeated.clear();
  }

  observe(value: MapObservation | undefined, capturedAt: number, now: number,
    geometry: string): MapDecision {
    if (!value || !value.readable || value.confidence < 0.85 ||
        now < capturedAt || now - capturedAt > MAP_MAX_AGE_MS) {
      // A blind interval cannot count as evidence for an enemy leaving.
      this.anchor = undefined;
      this.pending = '';
      this.confirmations = 0;
      return { text: '', status: '小地图不可读、置信不足或图像过期，本帧静默。' };
    }
    if (!this.anchor || this.geometry !== geometry || capturedAt <= this.lastTime ||
        capturedAt - this.lastTime > MAX_GAP_MS) {
      this.anchor = value;
      this.geometry = geometry;
      this.lastTime = capturedAt;
      this.pending = '';
      this.confirmations = 0;
      return { text: '', status: '小地图基线已建立，等待后续画面比较。' };
    }
    this.lastTime = capturedAt;
    let region = -1;
    let kind = '';
    let score = 0;
    for (let i = 0; i < 9; ++i) {
      const delta = value.cells[i] - this.anchor.cells[i];
      // Prefer a visible increase, especially a concentration of >=2 markers.
      const priority = delta > 0 ? delta + (value.cells[i] >= 2 ? 10 : 5) :
        delta < 0 ? -delta : 0;
      if (priority > score) {
        region = i;
        kind = delta > 0 ? (value.cells[i] >= 2 ? 'cluster' : 'increase') : 'decrease';
        score = priority;
      }
    }
    if (region < 0) {
      this.anchor = value;
      this.pending = '';
      this.confirmations = 0;
      return { text: '', status: '没有可靠的新变化，保持静默。' };
    }
    const key = `${kind}:${region}`;
    this.confirmations = this.pending === key ? this.confirmations + 1 : 1;
    this.pending = key;
    if (this.confirmations < 2) {
      return { text: '', status: '发现小地图变化，等待下一次观测确认。' };
    }
    this.anchor = value;
    this.pending = '';
    this.confirmations = 0;
    const last = this.repeated.get(key);
    if (now - this.lastSpoken < COOLDOWN_MS || (last !== undefined && now - last < REPEAT_MS)) {
      return { text: '', status: '变化已确认，处于提醒冷却期。' };
    }
    this.lastSpoken = now;
    this.repeated.set(key, now);
    const position = REGIONS[region];
    const text = kind === 'cluster' ? `小地图${position}敌方标记聚集，注意。` :
      kind === 'increase' ? `小地图${position}敌方标记增多。` :
      `小地图${position}敌方可见标记减少，留意视野。`;
    return { text: text, status: '连续两次观测确认变化；描述可见标记，不推断支援路线。' };
  }
}
