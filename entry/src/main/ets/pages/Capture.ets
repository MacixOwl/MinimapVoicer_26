import common from '@ohos.app.ability.common';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import deviceInfo from '@ohos.deviceInfo';
import image from '@ohos.multimedia.image';
import { PhoneScreen, ScreenStatus } from '../demo/PhoneScreen';
import { parseCaptureIntervalMs } from '../demo/CaptureInterval';
import { CaptureFeedback } from '../demo/CaptureFeedback';

@Entry
@Component
struct Capture {
  @StorageLink('captureIntervalText') private captureIntervalText: string = '10';
  @StorageLink('captureFeedbackEnabled') private captureFeedbackEnabled: boolean = false;
  @StorageLink('captureFeedbackStatus') private captureFeedbackStatus: string = '截图反馈已关闭。';
  @State private endpoint: string = '';
  @State private supported: boolean = false;
  @State private active: boolean = false;
  @State private transitioning: boolean = false;
  @State private message: string = '正在检查手机录屏接口……';
  @State private report: string = '';
  @State private backgroundMessage: string = '';
  @State private preview: image.PixelMap | undefined = undefined;
  private backgroundRunning: boolean = false;
  private timer: number = -1;
  private polling: boolean = false;
  private sequence: number = 0;
  private lastId: string = '';

  aboutToAppear(): void {
    void this.inspect();
  }

  onPageShow(): void {
    if (this.active) void this.poll(this.sequence);
  }

  aboutToDisappear(): void {
    void this.stop();
    const preview = this.preview;
    this.preview = undefined;
    void preview?.release();
  }

  private async inspect(): Promise<void> {
    try {
      this.show(await PhoneScreen.status());
    } catch (error) {
      this.message = `检测失败：${(error as Error).message}`;
    }
  }

  private show(state: ScreenStatus): void {
    this.supported = state.supported;
    const descriptions: Map<string, string> = new Map<string, string>([
      ['idle', '接口检测完成，尚未申请屏幕采集。'],
      ['unsupported', '本机缺少公开的系统授权录屏接口，无法开始采集。'],
      ['waiting_consent', '等待系统录屏授权。请在系统弹窗中手动选择允许。'],
      ['capturing', state.privateScene ? '系统报告隐私画面，暂停取帧。' :
        `正在采集：每 ${state.intervalMs / 1000} 秒一帧，已取 ${state.frames} 帧，上传成功 ${state.uploads} 帧。`],
      ['denied', '用户拒绝或取消了录屏授权，未启动采集。'],
      ['stopped_by_system', '用户或系统已中止录屏，采集已停止。'],
      ['stopped', '已停止采集。'],
      ['error', '录屏失败，请查看检测结果。']
    ]);
    this.message = state.supported ? (descriptions.get(state.state) ?? state.state) :
      '本机缺少公开的系统授权录屏接口，不能用此应用采集游戏画面。';
    this.report = `设备：${deviceInfo.displayVersion}\nSDK API：${deviceInfo.sdkApiVersion}` +
      `\n所需公开回调：API ${state.requiredApi}\n状态：${state.state}` +
      `\n系统已确认授权：${state.authorized ? '是' : '否'}` +
      `\n本次采集间隔：${state.intervalMs / 1000} 秒` +
      `\n图片：${state.width} × ${state.height}，${state.frames} 帧` +
      `\n最近一帧：${state.capturedAt ? new Date(state.capturedAt).toLocaleTimeString() : '无'}` +
      `\n缺失接口：${state.missing.length ? state.missing.join(', ') : '无'}` +
      `\n采集错误：${state.error || '无'}\n上传错误：${state.uploadError || '无'}` +
      `\n后端回复：${state.reply || '无'}`;
  }

  private async start(): Promise<void> {
    if (this.active || this.transitioning) return;
    const origin = this.endpoint.trim().replace(/\/+$/, '');
    if (origin && !/^https?:\/\/[^/\s?#@]+$/.test(origin)) {
      this.message = '地址格式为 http://服务器IP:8765；留空可只在手机验证截屏。';
      return;
    }
    let intervalMs: number;
    try {
      intervalMs = parseCaptureIntervalMs(this.captureIntervalText);
    } catch (error) {
      this.message = (error as Error).message;
      return;
    }
    this.transitioning = true;
    const sequence = ++this.sequence;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.show(await PhoneScreen.start(context, origin, intervalMs));
      if (sequence !== this.sequence) return;
      CaptureFeedback.begin();
      this.active = true;
      this.lastId = '';
      try {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
          operationType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        if (sequence !== this.sequence) return;
        await backgroundTaskManager.startBackgroundRunning(
          context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
        this.backgroundRunning = true;
        this.backgroundMessage = '已申请后台持续任务；请切到游戏后再返回检查帧数和预览。';
      } catch (error) {
        this.backgroundMessage = `后台任务申请失败：${(error as Error).message}。后台采集仍需真机确认。`;
      }
      if (sequence !== this.sequence) {
        await this.stop();
        return;
      }
      this.timer = setInterval(() => void this.poll(sequence), 1000);
      void this.poll(sequence);
    } catch (error) {
      const message = `无法开始：${(error as Error).message}`;
      await this.stop();
      this.message = message;
    } finally {
      this.transitioning = false;
    }
  }

  private async poll(sequence: number): Promise<void> {
    if (this.polling || sequence !== this.sequence) return;
    this.polling = true;
    try {
      const state = await PhoneScreen.status();
      if (sequence !== this.sequence) return;
      this.show(state);
      if (['denied', 'stopped_by_system', 'error'].indexOf(state.state) >= 0) {
        const message = this.message;
        await this.stop();
        this.message = message;
        return;
      }
      const frame = await PhoneScreen.read(this.lastId);
      if (!frame || sequence !== this.sequence) return;
      const source = image.createImageSource(frame.bytes);
      try {
        const pixels = await source.createPixelMap();
        if (sequence !== this.sequence) {
          await pixels.release();
          return;
        }
        const previous = this.preview;
        this.preview = pixels;
        this.lastId = frame.id;
        await previous?.release();
      } finally {
        await source.release();
      }
    } catch (error) {
      this.message = `读取状态失败：${(error as Error).message}`;
    } finally {
      this.polling = false;
    }
  }

  private async stop(): Promise<void> {
    ++this.sequence;
    this.active = false;
    clearInterval(this.timer);
    this.timer = -1;
    await CaptureFeedback.stop();
    try {
      await PhoneScreen.stop();
    } catch (error) {
      this.message = `停止采集失败：${(error as Error).message}`;
    } finally {
      if (this.backgroundRunning) {
        this.backgroundRunning = false;
        try {
          await backgroundTaskManager.stopBackgroundRunning(getContext(this) as common.UIAbilityContext);
        } catch (error) {
          this.backgroundMessage = `停止后台任务失败：${(error as Error).message}`;
        }
      }
    }
    await this.inspect();
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('手机游戏截屏测试').fontSize(26).fontWeight(FontWeight.Bold)
        Text('先申请系统录屏授权。允许后按设置的间隔保存截图，可切到游戏验证。')
          .fontSize(16)
        Text('截图间隔（秒）').fontSize(15)
        TextInput({ text: this.captureIntervalText, placeholder: '默认 10，范围 1～300' })
          .type(InputType.Number).maxLength(3)
          .enabled(!this.active && !this.transitioning)
          .onChange((value: string) => { this.captureIntervalText = value; })
        Text('停止后修改，下次开始生效；与首页共享本次设置。首帧需在系统允许后等待一个完整间隔。')
          .fontSize(13).fontColor('#495970')
        Row({ space: 12 }) {
          Text('截图成功提示').layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.captureFeedbackEnabled })
            .onChange((value: boolean) => { void CaptureFeedback.setEnabled(value); })
        }.width('100%')
        Button('测试提示（不截图）').enabled(this.captureFeedbackEnabled)
          .onClick(() => { void CaptureFeedback.test(); })
        Text('前台约1.5秒短提示，最多每2秒一次；游戏中使用临时系统通知。请允许通知并在系统设置开启横幅，游戏免打扰可能拦截。')
          .fontSize(13).fontColor('#495970')
        Text(this.captureFeedbackStatus).fontSize(13).fontColor('#495970')
        Text('上传地址（可留空）').fontSize(15)
        TextInput({ text: this.endpoint, placeholder: 'http://服务器IP:8765' })
          .enabled(!this.active && !this.transitioning)
          .onChange((value: string) => { this.endpoint = value; })
        Text('留空只在手机保留最新截图；填写后将截图发送到该地址的 /analyze。无需下载模型。')
          .fontSize(13).fontColor('#495970')
        Row({ space: 8 }) {
          Button('申请系统授权并开始').layoutWeight(1)
            .enabled(this.supported && !this.active && !this.transitioning)
            .onClick(() => void this.start())
          Button('停止').enabled(this.active && !this.transitioning)
            .onClick(() => void this.stop())
        }.width('100%')
        Button('重新检测').enabled(!this.active && !this.transitioning)
          .onClick(() => void this.inspect())
        Text(this.message).fontSize(17).fontWeight(FontWeight.Medium)
        if (this.backgroundMessage) {
          Text(this.backgroundMessage).fontSize(13)
        }
        if (this.preview) {
          Text('最近采集的画面').fontSize(15)
          Image(this.preview).width('100%').height(200).objectFit(ImageFit.Contain)
        }
        Text(this.report).fontSize(13).copyOption(CopyOptions.LocalDevice)
          .width('100%').padding(12).backgroundColor(Color.White)
      }.padding(20).width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor('#F3F6FB')
  }
}
