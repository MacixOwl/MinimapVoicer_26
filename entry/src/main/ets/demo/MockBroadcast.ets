import { DemoReply } from './DemoApi';

export const MOCK_REPLY_TEXT: string = '这是一条模拟回复，请留意小地图。';

export interface MockFrame {
  id: string;
  bytes: Uint8Array;
  mime: string;
  simulated: boolean;
}

export interface MockReplyService {
  send(frame: MockFrame): Promise<DemoReply>;
}

export class MockSmartServe implements MockReplyService {
  async send(frame: MockFrame): Promise<DemoReply> {
    if (!frame.id || frame.bytes.byteLength === 0 || !/^image\/(png|jpeg)$/.test(frame.mime)) {
      throw new Error('模拟请求缺少有效画面');
    }
    console.info(`GameVoice mock request ${frame.id}: ${frame.bytes.byteLength} bytes`);
    return { frame_id: frame.id, text: MOCK_REPLY_TEXT };
  }
}

export class MockBroadcastHooks {
  capture: () => Promise<MockFrame | undefined>;
  captured: (frame: MockFrame) => Promise<void>;
  speak: (reply: DemoReply) => Promise<void>;
  cancelSpeech: () => void;
  onReply: (reply: DemoReply) => void;
  onSpoken: () => void;
  onError: (message: string) => void;

  constructor(capture: () => Promise<MockFrame | undefined>, captured: (frame: MockFrame) => Promise<void>,
    speak: (reply: DemoReply) => Promise<void>, cancelSpeech: () => void,
    onReply: (reply: DemoReply) => void, onSpoken: () => void, onError: (message: string) => void) {
    this.capture = capture;
    this.captured = captured;
    this.speak = speak;
    this.cancelSpeech = cancelSpeech;
    this.onReply = onReply;
    this.onSpoken = onSpoken;
    this.onError = onError;
  }
}

export class MockBroadcast {
  private hooks: MockBroadcastHooks;
  private service: MockReplyService;
  private running: boolean = false;
  private generation: number = 0;
  private timer: number = -1;
  private pending: Promise<void> | undefined;

  constructor(hooks: MockBroadcastHooks, service: MockReplyService = new MockSmartServe()) {
    this.hooks = hooks;
    this.service = service;
  }

  start(intervalMs: number): void {
    if (!Number.isInteger(intervalMs) || intervalMs < 1000 || intervalMs > 300000) {
      throw new Error('播报间隔须为 1～300 秒');
    }
    if (this.running || this.pending) throw new Error('请先等待上一轮结束');
    this.running = true;
    const generation = ++this.generation;
    this.timer = setInterval(() => this.queue(generation), intervalMs);
    this.queue(generation);
  }

  async stop(): Promise<void> {
    this.running = false;
    ++this.generation;
    clearInterval(this.timer);
    this.timer = -1;
    this.hooks.cancelSpeech();
    await this.pending;
  }

  private current(generation: number): boolean {
    return this.running && generation === this.generation;
  }

  private queue(generation: number): void {
    if (!this.current(generation) || this.pending) return;
    const pending = this.tick(generation);
    this.pending = pending;
    void pending.then(() => {
      if (this.pending === pending) this.pending = undefined;
    });
  }

  private async tick(generation: number): Promise<void> {
    try {
      const frame = await this.hooks.capture();
      if (!frame || !this.current(generation)) return;
      await this.hooks.captured(frame);
      if (!this.current(generation)) return;
      const reply = await this.service.send(frame);
      if (!this.current(generation)) return;
      this.hooks.onReply(reply);
      await this.hooks.speak(reply);
      if (this.current(generation)) this.hooks.onSpoken();
    } catch (error) {
      if (!this.current(generation)) return;
      this.running = false;
      ++this.generation;
      clearInterval(this.timer);
      this.timer = -1;
      this.hooks.cancelSpeech();
      this.hooks.onError((error as Error).message);
    }
  }
}
