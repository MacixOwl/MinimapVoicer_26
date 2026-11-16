import common from '@ohos.app.ability.common';
import wantAgent from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import router from '@ohos.router';
import { DemoApi, DemoReply } from '../demo/DemoApi';
import { captureFrame, Frame, NATIVE_SCREEN_ENABLED } from '../demo/FrameSource';
import { VoicePlayer } from '../demo/VoicePlayer';
import { LocalRuntime } from '../demo/LocalRuntime';
import { LocalNeuralSpeech } from '../demo/LocalNeuralSpeech';
import { PhoneScreen } from '../demo/PhoneScreen';
import { TEST_BROADCAST } from '../demo/BroadcastPolicy';
import { parseMinimapRoi } from '../demo/MinimapTracker';
import hidebug from '@ohos.hidebug';
import { parseCaptureIntervalMs } from '../demo/CaptureInterval';
import { CaptureFeedback } from '../demo/CaptureFeedback';
import { ROCKCHIP_MOCK_ONLY } from '../demo/DemoMode';

// Initial CPU inference may take longer than one capture interval.
// Keep at most one frame in flight; display its age instead of building a queue.
const STALE_AFTER_MS = 180000;

@Entry
@Component
struct Index {
  @StorageLink('captureIntervalText') private captureIntervalText: string = '10';
  @StorageLink('captureFeedbackEnabled') private captureFeedbackEnabled: boolean = false;
  @StorageLink('captureFeedbackStatus') private captureFeedbackStatus: string = '截图反馈已关闭。';
  @State private endpoint: string = 'http://192.168.1.100:8765';
  @State private inference: string = ROCKCHIP_MOCK_ONLY ? 'peer' : 'local';
  @State private peerEndpoint: string = 'http://192.168.1.100:8081';
  @State private downloading: boolean = false;
  @State private source: string = 'sample';
  @State private running: boolean = false;
  @State private transitioning: boolean = false;
  @State private previewing: boolean = false;
  @State private voiceSource: string = 'local';
  @State private ttsEndpoint: string = 'http://192.168.1.100:8765';
  @State private testText: string = TEST_BROADCAST;
  @State private analysis: string = 'single';
  @State private minimapRoi: string = '0,0,0.22,0.36';
  @State private minimapPreview: string = '';
  @State private processingMs: number = 0;
  @State private resourceText: string = '尚未读取本进程内存；返回此页面后可手动读取。';
  @State private status: string = ROCKCHIP_MOCK_ONLY ?
    '请先启动瑞芯微模拟服务并填写地址，再点击“发送一次并播报”。无需下载视觉模型。' :
    '默认本机看图、本机语音。先实时朗读，再下载视觉模型并测试样例链路。';
  @State private lastText: string = '等待回复';
  @State private count: number = 0;
  private timer: number = -1;
  private runId: number = 0;
  private background: boolean = false;
  private busy: boolean = false;
  private speaking: boolean = false;
  private lastFrameId: string = '';
  private api: DemoApi = new DemoApi();
  private voice?: VoicePlayer;
  private runtime?: LocalRuntime;
  private inferenceOrigin: string = '';

  aboutToAppear(): void {
    this.voice = new VoicePlayer(getContext(this) as common.UIAbilityContext);
    this.runtime = new LocalRuntime(getContext(this) as common.UIAbilityContext);
  }

  aboutToDisappear(): void {
    void this.stop();
  }

  private speechOrigin(): string {
    if (this.voiceSource !== 'neural') return '';
    const origin = this.ttsEndpoint.trim().replace(/\/+$/, '');
    if (!/^https?:\/\/[^/\s?#@]+$/.test(origin)) {
      throw new Error('请填写完整的神经 TTS 服务地址');
    }
    return origin;
  }

  private async start(): Promise<void> {
    if (this.running || this.transitioning || this.previewing || this.downloading || this.busy) {
      return;
    }
    if (ROCKCHIP_MOCK_ONLY && (this.inference !== 'peer' || this.voiceSource !== 'local' ||
      this.analysis !== 'single')) {
      this.status = '当前版本仅启用瑞芯微模拟转发和手机本机语音。';
      return;
    }
    const origin = this.endpoint.trim().replace(/\/+$/, '');
    if ((this.source === 'usb' || this.inference === 'fake') && !/^https?:\/\/[^/\s?#]+$/.test(origin)) {
      this.status = '请输入完整地址，例如 http://192.168.1.100:8765';
      return;
    }
    if (this.source === 'native' && !NATIVE_SCREEN_ENABLED) {
      this.status = '原生截屏构建需要 Full SDK 和设备认可的 CAPTURE_SCREEN 授权。';
      return;
    }
    let intervalMs: number;
    try {
      intervalMs = parseCaptureIntervalMs(this.captureIntervalText);
    } catch (error) {
      this.status = (error as Error).message;
      return;
    }
    const runId = ++this.runId;
    const context = getContext(this) as common.UIAbilityContext;
    this.transitioning = true;
    try {
      this.speechOrigin();
      if (this.analysis === 'changes' && this.inference !== 'fake') parseMinimapRoi(this.minimapRoi);
      this.api.resetTemporal();
      this.minimapPreview = '';
      if (this.voiceSource === 'local') {
        this.status = '正在校验并加载内置中文语音模型……';
        await LocalNeuralSpeech.prepare(context);
        if (runId !== this.runId) {
          this.transitioning = false;
          return;
        }
      }
      if (this.source === 'screen') {
        const screen = await PhoneScreen.status();
        if (runId !== this.runId) {
          this.transitioning = false;
          return;
        }
        if (!screen.supported) {
          throw new Error('本机缺少公开的系统授权录屏接口。请先打开「手机截屏测试」查看检测结果。');
        }
      }
      if (this.inference !== 'fake') {
        const peer = this.inference === 'peer' ? this.peerEndpoint.trim().replace(/\/+$/, '') : '';
        if (this.inference === 'peer' && !/^https?:\/\/[^/\s?#]+$/.test(peer)) {
          throw new Error('Peer 地址须为 SmartServe 路由端口，例如 http://服务器:8081');
        }
        this.status = '正在启动手机内 SmartServe 服务并校验模型……';
        this.inferenceOrigin = await this.runtime!.start(peer);
        if (runId !== this.runId) {
          this.transitioning = false;
          return;
        }
      }
    } catch (error) {
      this.transitioning = false;
      if (runId === this.runId) this.status = `启动失败：${(error as Error).message}`;
      return;
    }
    let backgroundError = '';
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      if (runId !== this.runId) {
        this.transitioning = false;
        return;
      }
      const localOnly = this.inference === 'local' && this.source !== 'usb' &&
        this.voiceSource !== 'neural';
      await backgroundTaskManager.startBackgroundRunning(context, localOnly ?
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK :
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      if (runId !== this.runId) {
        await backgroundTaskManager.stopBackgroundRunning(context);
        this.transitioning = false;
        return;
      }
      this.background = true;
    } catch (error) {
      backgroundError = (error as Error).message ?? String(error);
    }
    if (runId !== this.runId) {
      this.transitioning = false;
      return;
    }
    if (this.source === 'screen') {
      try {
        await PhoneScreen.start(context, '', intervalMs);
        CaptureFeedback.begin();
      } catch (error) {
        await this.stop();
        this.transitioning = false;
        this.status = `申请系统录屏失败：${(error as Error).message}`;
        return;
      }
      if (runId !== this.runId) {
        await PhoneScreen.stop();
        this.transitioning = false;
        return;
      }
    }
    this.running = true;
    this.transitioning = false;
    this.lastFrameId = '';
    this.count = 0;
    this.status = (this.background ? 'SmartServe 已启动，后台任务已申请。' :
      `后台任务申请失败：${backgroundError}。可先前台测试。`) + ` 截图间隔 ${intervalMs / 1000} 秒。`;
    this.timer = setInterval(() => void this.tick(origin, runId),
      this.source === 'screen' ? 1000 : intervalMs);
    void this.tick(origin, runId);
  }

  private async stop(): Promise<void> {
    ++this.runId;
    this.running = false;
    clearInterval(this.timer);
    this.timer = -1;
    this.api.cancel();
    this.api.resetTemporal();
    this.voice?.cancel();
    await CaptureFeedback.stop();
    let screenError = '';
    if (this.source === 'screen') {
      try {
        await PhoneScreen.stop();
      } catch (error) {
        screenError = (error as Error).message;
      }
    }
    if (this.background) {
      this.background = false;
      this.transitioning = true;
      try {
        await backgroundTaskManager.stopBackgroundRunning(getContext(this) as common.UIAbilityContext);
      } catch (error) {
        this.status = `停止后台任务失败：${(error as Error).message}`;
        return;
      } finally {
        this.transitioning = false;
      }
    }
    this.status = screenError ? `停止录屏失败：${screenError}` : '已停止';
  }

  private async tick(origin: string, runId: number): Promise<void> {
    if (this.busy || this.speaking || runId !== this.runId) {
      return;
    }
    this.busy = true;
    let start = Date.now();
    const roi = this.analysis === 'changes' ? this.minimapRoi : '';
    try {
      let reply: DemoReply | undefined;
      if (this.source === 'screen') {
        const state = await PhoneScreen.status();
        if (runId !== this.runId) return;
        if (!state.authorized) {
          this.status = state.state === 'waiting_consent' ? '等待用户在系统弹窗中允许录屏。' :
            `系统未授权或已停止录屏：${state.state}`;
          if (state.state !== 'waiting_consent') {
            const status = this.status;
            await this.stop();
            this.status = status;
          }
          return;
        }
        const captured = await PhoneScreen.read(this.lastFrameId);
        if (!captured || runId !== this.runId) return;
        this.lastFrameId = captured.id;
        start = captured.capturedAt;
        const frame = new Frame(new Uint8Array(captured.bytes), 'image/png');
        if (this.inference === 'fake') {
          reply = await this.api.analyze(origin, frame, captured.id);
        } else {
          this.status = '手机截图已取得，正在经 SmartServe 处理……';
          reply = await this.api.infer(this.inferenceOrigin, frame, captured.id, this.inference === 'peer',
            roi, start);
        }
      } else if (this.source === 'usb') {
        if (this.inference === 'fake') {
          reply = await this.api.latest(origin, this.lastFrameId);
        } else {
          const frame = await this.api.latestFrame(origin, this.lastFrameId);
          if (frame && runId === this.runId) {
            this.lastFrameId = frame.frame_id;
            this.status = 'USB 图像已回到手机，正经本机 SmartServe 处理……';
            reply = await this.api.inferEncoded(this.inferenceOrigin,
              frame.image_base64, frame.mime, frame.frame_id, this.inference === 'peer', roi, start);
          }
        }
      } else {
        const frame = await captureFrame(getContext(this) as common.UIAbilityContext, this.source === 'native');
        if (runId !== this.runId) {
          return;
        }
        if (this.inference === 'fake') {
          reply = await this.api.analyze(origin, frame, `hap-${start}-${runId}`);
        } else {
          this.status = '正在经手机内 SmartServe 推理，本帧处理完再采集下一帧……';
          reply = await this.api.infer(this.inferenceOrigin, frame, `hap-${start}-${runId}`,
            this.inference === 'peer', roi, start);
        }
      }
      if (runId !== this.runId) {
        return;
      }
      if (!reply) {
        this.status = '等待 USB 采集端发送下一帧。';
        return;
      }
      this.lastFrameId = reply.frame_id;
      this.processingMs = Date.now() - start;
      if (reply.minimap_preview) this.minimapPreview = reply.minimap_preview;
      if (!reply.text) {
        this.lastText = '本帧无需播报';
        this.status = reply.analysis_status ?? '没有新提醒。';
        return;
      }
      if (Date.now() - start > STALE_AFTER_MS) {
        this.status = '回复已过期，本帧跳过。';
        return;
      }
      this.lastText = reply.text;
      ++this.count;
      this.status = `第 ${this.count} 条 · 图像年龄 ${Date.now() - start} ms · ${ROCKCHIP_MOCK_ONLY ?
        '瑞芯微模拟回复（未执行推理）' : (this.inference === 'fake' ? '模拟' : 'SmartServe')}`;
      void this.announce(reply, runId);
    } catch (error) {
      if (runId === this.runId) {
        this.status = `处理失败：${(error as Error).message ?? String(error)}`;
      }
    } finally {
      this.busy = false;
    }
  }

  private async announce(reply: DemoReply, runId: number): Promise<void> {
    if (this.speaking || runId !== this.runId) {
      return;
    }
    this.speaking = true;
    try {
      await this.voice?.play(reply, this.speechOrigin(), this.voiceSource === 'local');
    } catch (error) {
      if (runId === this.runId) {
        this.status = `播报失败：${(error as Error).message ?? String(error)}`;
      }
    } finally {
      this.speaking = false;
    }
  }

  private async preview(sample: boolean): Promise<void> {
    if (this.running || this.transitioning || this.previewing || this.downloading || this.busy || this.speaking) return;
    this.previewing = true;
    const runId = ++this.runId;
    try {
      if (sample) {
        await this.voice?.playSample();
        if (runId !== this.runId) return;
        this.status = '测试样音播放完成；样音由同款内置小型 VITS 模型预生成。';
      } else {
        if (!this.testText.trim()) throw new Error('请输入要朗读的文本');
        await this.voice?.play({ frame_id: `preview-${Date.now()}`, text: this.testText.trim() },
          this.speechOrigin(), this.voiceSource === 'local');
        if (runId !== this.runId) return;
        this.status = this.voiceSource === 'local' ? '本机小型 VITS 已根据当前输入实时合成并播放。' :
          (this.voiceSource === 'neural' ? '服务器已根据当前输入实时合成并返回语音。' :
          '内置 eSpeak 已合成；中文可懂度尚未通过验收。');
      }
    } catch (error) {
      if (runId === this.runId) this.status = `试播失败：${(error as Error).message ?? String(error)}`;
    } finally {
      this.previewing = false;
    }
  }

  private async localSample(): Promise<void> {
    if (ROCKCHIP_MOCK_ONLY) return;
    if (this.running || this.transitioning || this.previewing || this.downloading || this.busy) return;
    this.previewing = true;
    this.busy = true;
    const runId = ++this.runId;
    const start = Date.now();
    const context = getContext(this) as common.UIAbilityContext;
    try {
      this.status = '正在加载本机语音模型和 SmartServe 视觉模型……';
      await LocalNeuralSpeech.prepare(context);
      if (runId !== this.runId) return;
      this.inferenceOrigin = await this.runtime!.start('');
      if (runId !== this.runId) return;
      const frame = await captureFrame(context, false);
      if (runId !== this.runId) return;
      this.status = '正在将内置样例图送入本机 SmartServe，等待真实模型回复……';
      const reply = await this.api.infer(this.inferenceOrigin, frame, `local-sample-${start}`, false);
      if (runId !== this.runId) return;
      this.processingMs = Date.now() - start;
      this.lastText = reply.text;
      this.status = '本机视觉模型已回复，正在用本机小型 VITS 实时朗读……';
      await this.voice?.play(reply, '', true);
      if (runId === this.runId) {
        this.status = `本机样例链路完成，共 ${Date.now() - start} ms；本次未测试游戏截屏。`;
      }
    } catch (error) {
      if (runId === this.runId) this.status = `本机样例失败：${(error as Error).message}`;
    } finally {
      this.busy = false;
      this.previewing = false;
    }
  }

  private async downloadModels(replace: boolean = false): Promise<void> {
    if (ROCKCHIP_MOCK_ONLY) return;
    if (this.running || this.transitioning || this.previewing || this.downloading || this.busy || this.speaking) return;
    this.downloading = true;
    try {
      await this.runtime?.release();
      await LocalNeuralSpeech.release();
      await this.runtime?.download((text: string) => { this.status = text; }, replace);
    } catch (error) {
      this.status = `下载失败：${(error as Error).message}`;
    } finally {
      this.downloading = false;
    }
  }

  private async releaseModel(): Promise<void> {
    if (this.running || this.transitioning || this.previewing || this.downloading || this.busy || this.speaking) return;
    this.transitioning = true;
    try {
      await this.runtime?.release();
      await LocalNeuralSpeech.release();
      this.status = 'SmartServe 已停止，视觉和语音模型内存已释放。';
    } catch (error) {
      this.status = `释放失败：${(error as Error).message}`;
    } finally {
      this.transitioning = false;
    }
  }

  private async openModelStorage(): Promise<void> {
    if (ROCKCHIP_MOCK_ONLY) return;
    if (this.running || this.transitioning || this.previewing || this.downloading || this.busy || this.speaking) return;
    this.transitioning = true;
    try {
      await this.runtime?.release();
      await LocalNeuralSpeech.release();
      await router.pushUrl({ url: 'pages/Models' });
    } catch (error) {
      this.status = `打开模型管理失败：${(error as Error).message}`;
    } finally {
      this.transitioning = false;
    }
  }

  private async mockSample(): Promise<void> {
    if (this.running || this.transitioning || this.previewing || this.downloading || this.busy || this.speaking) return;
    const peer = this.peerEndpoint.trim().replace(/\/+$/, '');
    if (!/^https?:\/\/[^/\s?#@]+$/.test(peer)) {
      this.status = '请输入瑞芯微模拟服务地址，例如 http://电脑IP:8081';
      return;
    }
    const runId = ++this.runId;
    const started = Date.now();
    const context = getContext(this) as common.UIAbilityContext;
    this.previewing = true;
    this.busy = true;
    try {
      this.status = '正在准备手机内置中文语音模型……';
      await LocalNeuralSpeech.prepare(context);
      if (runId !== this.runId) return;
      this.status = '正在启动手机 SmartServe 转发服务……';
      this.inferenceOrigin = await this.runtime!.start(peer);
      if (runId !== this.runId) return;
      const frame = await captureFrame(context, false);
      if (runId !== this.runId) return;
      this.status = 'SmartServe 正在向瑞芯微模拟服务发送样例请求……';
      const reply = await this.api.infer(this.inferenceOrigin, frame, `mock-sample-${started}-${runId}`, true);
      if (runId !== this.runId) return;
      this.processingMs = Date.now() - started;
      this.lastText = reply.text;
      this.status = '已收到固定文本，手机语音模型正在实时合成并播报……';
      await this.voice!.play(reply, '', true);
      if (runId !== this.runId) return;
      ++this.count;
      this.status = `模拟链路完成：已收到回复并播报，共 ${Date.now() - started} ms；未执行视觉推理。`;
    } catch (error) {
      if (runId === this.runId) this.status = `模拟链路失败：${(error as Error).message ?? String(error)}`;
    } finally {
      this.previewing = false;
      this.busy = false;
    }
  }

  private readResources(): void {
    // Manual foreground diagnostic only. Reading smaps is not a cheap frame task.
    try {
      const pss = Number(hidebug.getPss()) / 1024;
      const heap = Number(hidebug.getNativeHeapAllocatedSize()) / 1048576;
      this.resourceText = `本进程 PSS ${pss.toFixed(1)} MiB · 原生已分配堆 ${heap.toFixed(1)} MiB。` +
        '这是当前样本，不含游戏和服务端，也不是运行峰值。';
    } catch (error) {
      this.resourceText = `此设备未能读取资源数据：${(error as Error).message}`;
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('战场语音 Demo').fontSize(30).fontWeight(FontWeight.Bold).fontColor('#18263C')
        Text(ROCKCHIP_MOCK_ONLY ? 'SmartServe → 瑞芯微模拟服务 → 固定文本 → 手机语音' :
          '手机采集 → SmartServe → 简短文本 → 语音播报').fontSize(16).fontColor('#495970')
        if (ROCKCHIP_MOCK_ONLY) {
          Text('当前模拟后端仅返回测试文本，不识别画面。手机只转发请求并实时合成语音，无需下载视觉模型。')
            .fontSize(14).fontColor('#495970')
        }
        Text('截图间隔（秒）').fontSize(15)
        TextInput({ text: this.captureIntervalText, placeholder: '默认 10，范围 1～300' })
          .type(InputType.Number).maxLength(3)
          .enabled(!this.running && !this.transitioning && !this.previewing && !this.downloading && !this.busy)
          .onChange((value: string) => { this.captureIntervalText = value; })
        Text('默认 10 秒；停止后修改，下次开始生效。与独立截屏页共享本次设置。')
          .fontSize(13).fontColor('#495970')
        Row({ space: 12 }) {
          Text('截图成功提示').layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.captureFeedbackEnabled })
            .onChange((value: boolean) => { void CaptureFeedback.setEnabled(value); })
        }.width('100%')
        Button('测试提示（不截图）').enabled(this.captureFeedbackEnabled)
          .onClick(() => { void CaptureFeedback.test(); })
        Text('仅提示手机采集的成功截图，最多每2秒一次；前台短提示，后台临时通知。游戏横幅需系统通知设置允许。')
          .fontSize(13).fontColor('#495970')
        Text(this.captureFeedbackStatus).fontSize(13).fontColor('#495970')
        Button('手机截屏 · 独立测试')
          .enabled(!this.running && !this.transitioning && !this.previewing && !this.downloading && !this.busy)
          .onClick(() => { void router.pushUrl({ url: 'pages/Capture' }); })
        if (!ROCKCHIP_MOCK_ONLY) {
          Row({ space: 8 }) {
            Button('本机模型').layoutWeight(1)
              .backgroundColor(this.inference === 'local' ? '#18644F' : '#56667E')
              .onClick(() => { this.inference = 'local'; })
            Button('Peer 转发').layoutWeight(1)
              .backgroundColor(this.inference === 'peer' ? '#18644F' : '#56667E')
              .onClick(() => { this.inference = 'peer'; })
            Button('模拟').layoutWeight(1)
              .backgroundColor(this.inference === 'fake' ? '#18644F' : '#56667E')
              .onClick(() => { this.inference = 'fake'; })
          }.width('100%').enabled(!this.running && !this.transitioning && !this.previewing && !this.downloading && !this.busy)
          if (this.inference !== 'fake') {
            Row({ space: 8 }) {
              Button('小地图变化').layoutWeight(1)
                .backgroundColor(this.analysis === 'changes' ? '#18644F' : '#56667E')
                .onClick(() => { this.analysis = 'changes'; })
              Button('单帧提醒').layoutWeight(1)
                .backgroundColor(this.analysis === 'single' ? '#18644F' : '#56667E')
                .onClick(() => { this.analysis = 'single'; })
            }.width('100%').enabled(!this.running && !this.transitioning && !this.busy)
            if (this.analysis === 'changes') {
              Text('小地图范围 x,y,宽,高（0～1）').fontSize(15)
              TextInput({ text: this.minimapRoi, placeholder: '0,0,0.22,0.36' }).maxLength(80)
                .enabled(!this.running && !this.transitioning && !this.busy)
                .onChange((value: string) => { this.minimapRoi = value; })
              Text('默认范围只是初值，请按下方预览校准到完整小地图；位置按屏幕九宫格描述。无可靠变化时静默。')
                .fontSize(13).fontColor('#495970')
              if (this.minimapPreview) {
                Image(this.minimapPreview).width(180).height(180).objectFit(ImageFit.Contain)
              }
            }
          }
        }
        if (this.inference === 'peer') {
          Text(ROCKCHIP_MOCK_ONLY ? '瑞芯微模拟服务地址' : 'SmartServe Peer 地址（路由端口）').fontSize(15)
          TextInput({ text: this.peerEndpoint, placeholder: 'http://推理节点:8081' })
            .height(46).enabled(!this.running && !this.transitioning && !this.previewing && !this.busy)
            .onChange((value: string) => { this.peerEndpoint = value; })
        }
        if (ROCKCHIP_MOCK_ONLY) {
          Button(this.previewing ? '取消本次请求 / 试播' : '发送一次并播报 · 样例图')
            .enabled(!this.running && !this.transitioning && !this.downloading &&
              (this.previewing || (!this.busy && !this.speaking)))
            .onClick(() => {
              if (this.previewing) {
                void this.stop();
              } else {
                void this.mockSample();
              }
            })
          Text('先使用样例图验证请求与播报；也可在下方选择图像源后开始循环测试。')
            .fontSize(13).fontColor('#495970')
        }
        if (!ROCKCHIP_MOCK_ONLY && this.inference === 'local') {
          Row({ space: 8 }) {
            Button('下载模型 · 704 MiB').layoutWeight(1)
              .enabled(!this.running && !this.previewing && !this.downloading && !this.transitioning && !this.busy)
              .onClick(() => void this.downloadModels())
            Button('释放模型').layoutWeight(1)
              .enabled(!this.running && !this.previewing && !this.downloading && !this.transitioning && !this.busy)
              .onClick(() => void this.releaseModel())
          }.width('100%')
          Button('校验失败时重新下载全部文件')
            .enabled(!this.running && !this.previewing && !this.downloading && !this.transitioning && !this.busy)
            .onClick(() => void this.downloadModels(true))
        }
        if (!ROCKCHIP_MOCK_ONLY) {
          Button('模型存储与卸载 · 备份 / 恢复 / 删除')
            .enabled(!this.running && !this.previewing && !this.downloading &&
              !this.transitioning && !this.busy && !this.speaking)
            .onClick(() => { void this.openModelStorage(); })
          Button('本机样例跑通一次 · 无需服务器')
            .enabled(!this.running && !this.transitioning && !this.previewing && !this.downloading && !this.busy)
            .onClick(() => void this.localSample())
        }
        if (this.source === 'usb' || this.inference === 'fake') {
          Text('USB 中继 / 模拟后端地址').fontSize(15).fontWeight(FontWeight.Medium)
          TextInput({ text: this.endpoint, placeholder: 'http://电脑或服务器IP:8765' })
            .height(46)
            .enabled(!this.running && !this.transitioning)
            .onChange((value: string) => { this.endpoint = value; })
        }
        Row({ space: 8 }) {
          Button('样例图').layoutWeight(1)
            .backgroundColor(this.source === 'sample' ? '#18644F' : '#56667E')
            .onClick(() => { this.source = 'sample'; })
          Button('USB 实时').layoutWeight(1)
            .backgroundColor(this.source === 'usb' ? '#18644F' : '#56667E')
            .onClick(() => { this.source = 'usb'; })
          Button('手机采集').layoutWeight(1)
            .backgroundColor(this.source === 'screen' ? '#18644F' : '#56667E')
            .onClick(() => { this.source = 'screen'; })
          if (NATIVE_SCREEN_ENABLED) {
            Button('原生截屏').layoutWeight(1)
              .backgroundColor(this.source === 'native' ? '#18644F' : '#56667E')
              .onClick(() => { this.source = 'native'; })
          }
        }.width('100%').enabled(!this.running && !this.transitioning && !this.busy)
        Row({ space: 12 }) {
          Button(this.running ? '停止' : (ROCKCHIP_MOCK_ONLY ? '开始循环测试' : '开始'))
            .layoutWeight(1)
            .backgroundColor(this.running ? '#A03C43' : '#18644F')
            .enabled(!this.transitioning && !this.previewing && !this.downloading && (this.running || !this.busy))
            .onClick(() => {
              if (this.running) {
                void this.stop();
              } else {
                void this.start();
              }
            })
          Button('播放测试样音').layoutWeight(1)
            .enabled(!this.running && !this.transitioning && !this.previewing && !this.downloading && !this.busy && !this.speaking)
            .onClick(() => void this.preview(true))
        }.width('100%')
        Text('实时语音合成').fontSize(16).fontWeight(FontWeight.Bold)
        if (!ROCKCHIP_MOCK_ONLY) {
          Row({ space: 8 }) {
            Button('本机小模型').layoutWeight(1)
              .backgroundColor(this.voiceSource === 'local' ? '#18644F' : '#56667E')
              .onClick(() => { this.voiceSource = 'local'; })
            Button('服务器神经 TTS').layoutWeight(1)
              .backgroundColor(this.voiceSource === 'neural' ? '#18644F' : '#56667E')
              .onClick(() => { this.voiceSource = 'neural'; })
            Button('内置 eSpeak').layoutWeight(1)
              .backgroundColor(this.voiceSource === 'embedded' ? '#18644F' : '#56667E')
              .onClick(() => { this.voiceSource = 'embedded'; })
          }.width('100%').enabled(!this.running && !this.previewing && !this.transitioning)
        }
        if (this.voiceSource === 'neural') {
          TextInput({ text: this.ttsEndpoint, placeholder: 'http://语音服务器IP:8765' })
            .enabled(!this.running && !this.previewing && !this.transitioning)
            .onChange((value: string) => { this.ttsEndpoint = value; })
        } else if (this.voiceSource === 'local') {
          Text('已内置约 31 MiB 中文 VITS 资源，CPU 实时合成，无需语音 API 或服务器。')
            .fontSize(13).fontColor('#495970')
        } else {
          Text('内置引擎不需要联网，但当前中文输出尚未通过可懂度验收。').fontSize(13)
        }
        TextInput({ text: this.testText, placeholder: '输入要实时朗读的短句' }).maxLength(80)
          .enabled(!this.running && !this.previewing)
          .onChange((value: string) => { this.testText = value; })
        Button('实时朗读输入文本')
          .enabled(!this.running && !this.transitioning && !this.previewing && !this.downloading && !this.busy && !this.speaking)
          .onClick(() => void this.preview(false))
        Column({ space: 8 }) {
          Text('运行状态').fontSize(14).fontWeight(FontWeight.Bold)
          Text(this.status).fontSize(15).fontColor('#495970')
          Text(this.lastText).fontSize(20).fontWeight(FontWeight.Medium)
          Text(`最近请求处理 ${this.processingMs} ms（不含 TTS 和播放）`).fontSize(13)
        }.alignItems(HorizontalAlign.Start).width('100%').padding(16).backgroundColor(Color.White).borderRadius(16)
        Button('读取本进程内存').onClick(() => this.readResources())
        Text(this.resourceText).fontSize(13).fontColor('#495970')
        Text('手机采集须通过系统录屏授权，按设置的间隔取帧；设备缺少接口时会停止。请先做独立截屏测试。推理忙时只取最新帧。')
          .fontSize(13).fontColor('#495970')
      }.padding(20).width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor('#F3F6FB')
  }
}
