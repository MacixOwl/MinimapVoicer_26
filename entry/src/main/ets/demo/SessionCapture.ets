import common from '@ohos.app.ability.common';
import { PhoneScreen } from './PhoneScreen';
import { MockFrame } from './MockBroadcast';

export class SessionCapture {
  public usesScreen: boolean = false;
  private context: common.UIAbilityContext;
  private lastId: string = '';
  private sequence: number = 0;
  private sample: Uint8Array | undefined;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async start(intervalMs: number): Promise<string> {
    this.lastId = '';
    this.sequence = 0;
    const state = await PhoneScreen.status();
    this.usesScreen = state.supported;
    if (this.usesScreen) {
      await PhoneScreen.start(this.context, '', intervalMs);
      return '系统录屏，等待授权后采集';
    }
    this.sample = await this.context.resourceManager.getRawFileContent('sample.png');
    return '样例画面 · 模拟截图';
  }

  async read(): Promise<MockFrame | undefined> {
    if (this.usesScreen) {
      const state = await PhoneScreen.status();
      if (['denied', 'stopped_by_system', 'stopped', 'error', 'unsupported'].indexOf(state.state) >= 0) {
        throw new Error(state.error || '系统录屏已取消或停止，请重新开始');
      }
      const frame = await PhoneScreen.read(this.lastId);
      if (!frame) return undefined;
      this.lastId = frame.id;
      return { id: frame.id, bytes: new Uint8Array(frame.bytes), mime: 'image/png', simulated: false };
    }
    if (!this.sample) throw new Error('请先启动画面采集');
    return {
      id: `sample-${Date.now()}-${++this.sequence}`,
      bytes: this.sample,
      mime: 'image/png',
      simulated: true
    };
  }

  async stop(): Promise<void> {
    const usesScreen = this.usesScreen;
    this.usesScreen = false;
    this.sample = undefined;
    this.lastId = '';
    if (usesScreen) await PhoneScreen.stop();
  }
}
