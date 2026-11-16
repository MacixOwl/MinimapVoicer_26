import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import notificationManager from '@ohos.notificationManager';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { CloudPhoneScreen as PhoneScreen } from '../demo/CloudPhoneScreen';
import { VoicePlayer } from '../demo/VoicePlayer';
import { LocalNeuralSpeech } from '../demo/LocalNeuralSpeech';
import { BattleBriefingGate, DEFAULT_SPEECH_RATE, SPEECH_PREVIEW, quietBriefing,
  savedSpeechRate } from '../demo/BattleBriefing';
import { parseCaptureIntervalMs } from '../demo/CaptureInterval';
import { parseMinimapRoi } from '../demo/MinimapTracker';
import { DEFAULT_MINIMAP_ROI, LEGACY_MINIMAP_ROI } from '../demo/MinimapCrop';
import { CloudImage, cropCloudMinimap, selectCloudScreenshot } from '../demo/CloudImages';
import { CloudBattleApi, CloudBattleConfig, validateCloudConfig } from '../demo/CloudBattleApi';
import { CLOUD_FRAME_MAX_AGE_MS, LIVE_FRAME_MAX_AGE_MS, LIVE_CAPTURE_INTERVAL_MS,
  CloudFrameExpiredError, assertCloudFrameFresh } from '../demo/CloudTiming';

@Entry
@Component
struct CloudBattle {
  @State private endpoint: string = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
  @State private apiKey: string = '';
  @State private model: string = 'qwen3.6-flash';
  @State private roi: string = DEFAULT_MINIMAP_ROI;
  @State private intervalText: string = '10';
  @State private speechRate: number = DEFAULT_SPEECH_RATE;
  @State private allyColor: string = 'unknown';
  @State private pageIndex: number = 0;
  @State private running: boolean = false;
  @State private busy: boolean = false;
  @State private transitioning: boolean = false;
  @State private hasScreenshot: boolean = false;
  @State private status: string = '填写云端配置，先导入截图校准小地图，再开始自动播报。';
  @State private captureReport: string = '正在检测自动截屏能力……';
  @State private preview: string = '';
  @State private previewCapturedAt: string = '';
  @State private sourcePreview: string = '';
  @State private sourceAspectRatio: number = 16 / 9;
  @State private cropBounds: number[] = [0, 0, 1, 1];
  @State private imageIssue: string = '';
  @State private reply: string = '';
  @State private count: number = 0;
  @State private settingsError: string = '';
  @State private liveReport: string = '';
  @State private analysisReport: string = '';
  private cloudPreferences?: preferences.Preferences;
  private savingCloudSettings: boolean = false;
  private cloudSettingsDirty: boolean = false;
  private api: CloudBattleApi = new CloudBattleApi();
  private voice?: VoicePlayer;
  private briefings: BattleBriefingGate = new BattleBriefingGate();
  private selected?: Uint8Array;
  private config?: CloudBattleConfig;
  private runRoi: string = '';
  private runIntervalMs: number = 10000;
  private nextAnalysisAt: number = 0;
  private pager: SwiperController = new SwiperController();
  private sequence: number = 0;
  private timer: number = -1;
  private lastId: string = '';
  private consentAt: number = 0;
  private lastFrameAt: number = 0;
  private frameWaitMs: number = 30000;
  private backgroundRunning: boolean = false;
  private starting: boolean = false;
  private stopping: boolean = false;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
    this.restoreCloudSettings();
    this.voice = new VoicePlayer(getContext(this) as common.UIAbilityContext);
    void this.inspect();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    void this.flushCloudSettings();
    this.apiKey = '';
    this.selected = undefined;
    void this.stop();
  }

  private current(sequence: number): boolean {
    return !this.disposed && sequence === this.sequence;
  }

  private restoreCloudSettings(): void {
    try {
      this.cloudPreferences = preferences.getPreferencesSync(getContext(this) as common.UIAbilityContext,
        { name: 'cloud_battle_settings' });
      this.endpoint = this.cloudPreferences.getSync('endpoint', this.endpoint) as string;
      this.apiKey = this.cloudPreferences.getSync('apiKey', '') as string;
      this.model = this.cloudPreferences.getSync('model', this.model) as string;
      this.roi = this.cloudPreferences.getSync('roi', this.roi) as string;
      this.intervalText = this.cloudPreferences.getSync('intervalText', this.intervalText) as string;
      this.speechRate = savedSpeechRate(this.cloudPreferences.getSync('speechRate', DEFAULT_SPEECH_RATE) as number);
      this.allyColor = this.cloudPreferences.getSync('allyColor', this.allyColor) as string;
      this.settingsError = '';
      let migrate = false;
      if ((this.cloudPreferences.getSync('imagePipelineVersion', 0) as number) < 3) {
        migrate = true;
      }
      if ((this.cloudPreferences.getSync('minimapPresetVersion', 0) as number) < 1) {
        if (this.roi === LEGACY_MINIMAP_ROI) {
          this.roi = DEFAULT_MINIMAP_ROI;
        }
        migrate = true;
      }
      if (migrate) this.saveCloudSettings();
    } catch (_) {
      this.settingsError = '无法读取已保存的云端配置，请重新输入。';
    }
  }

  private saveCloudSettings(): void {
    try {
      const store = this.cloudPreferences || preferences.getPreferencesSync(getContext(this) as common.UIAbilityContext,
        { name: 'cloud_battle_settings' });
      this.cloudPreferences = store;
      store.putSync('endpoint', this.endpoint);
      store.putSync('apiKey', this.apiKey);
      store.putSync('model', this.model);
      store.putSync('roi', this.roi);
      store.putSync('intervalText', this.intervalText);
      store.putSync('speechRate', this.speechRate);
      store.putSync('allyColor', this.allyColor);
      store.putSync('squareCrop', false);
      store.putSync('imagePipelineVersion', 3);
      store.putSync('minimapPresetVersion', 1);
      this.cloudSettingsDirty = true;
      void this.flushCloudSettings();
    } catch (_) {
      this.settingsError = '云端配置保存失败，下次打开可能需要重新输入。';
    }
  }

  private async flushCloudSettings(): Promise<void> {
    const store = this.cloudPreferences;
    if (this.savingCloudSettings || !store) return;
    this.savingCloudSettings = true;
    try {
      while (this.cloudSettingsDirty) {
        this.cloudSettingsDirty = false;
        await store.flush();
      }
      if (!this.disposed) this.settingsError = '';
    } catch (_) {
      this.cloudSettingsDirty = true;
      if (!this.disposed) this.settingsError = '云端配置保存失败，下次打开可能需要重新输入。';
    } finally {
      this.savingCloudSettings = false;
    }
  }

  private settings(): CloudBattleConfig {
    const config: CloudBattleConfig = {
      endpoint: this.endpoint.trim(), apiKey: this.apiKey.trim(), model: this.model.trim(), allyColor: this.allyColor
    };
    validateCloudConfig(config);
    parseMinimapRoi(this.roi);
    return config;
  }

  private report(text: string): void {
    this.status = text;
    console.info(`CloudBattle: ${text}`);
  }

  private async inspect(): Promise<void> {
    try {
      const state = await PhoneScreen.status();
      if (this.disposed) return;
      this.captureReport = state.supported ? '检测到系统授权采集接口；启动后请允许系统录屏授权。' :
        `自动截屏不可用，需要API ${state.requiredApi}公开接口。缺失：${state.missing.join(', ')}。可先导入系统截图完成分析与播报。`;
    } catch (_) {
      if (!this.disposed) this.captureReport = '无法检测自动截屏接口，可先尝试导入系统截图。';
    }
  }

  private async importScreenshot(): Promise<void> {
    if (this.running || this.busy || this.transitioning) return;
    this.busy = true;
    const sequence = ++this.sequence;
    try {
      const bytes = await selectCloudScreenshot();
      if (!bytes || !this.current(sequence)) return;
      const cropped = await cropCloudMinimap(bytes, this.roi, Date.now(), 'import-preview');
      if (!this.current(sequence)) return;
      this.selected = bytes;
      this.hasScreenshot = true;
      this.showCrop(cropped);
      this.reply = '';
      this.status = this.imageIssue || '已在手机裁剪；确认预览只包含小地图后，点击分析并播报。';
    } catch (error) {
      if (this.current(sequence)) this.status = `导入失败：${(error as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  private async previewScreenshot(): Promise<void> {
    if (!this.selected || this.running || this.busy || this.transitioning) return;
    this.busy = true;
    const sequence = ++this.sequence;
    try {
      const cropped = await cropCloudMinimap(this.selected, this.roi, Date.now(), 'import-preview');
      if (this.current(sequence)) {
        this.showCrop(cropped);
        this.status = this.imageIssue || '裁剪预览已更新，请确认地图完整、没有右侧状态头像。';
      }
    } catch (error) {
      if (this.current(sequence)) this.status = (error as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private async analyzeScreenshot(): Promise<void> {
    if (!this.selected || this.running || this.busy || this.transitioning) return;
    this.busy = true;
    const sequence = ++this.sequence;
    try {
      const config = this.settings();
      this.api.resetStats();
      this.analysisReport = '';
      this.status = '正在准备手机语音模型……';
      await LocalNeuralSpeech.prepare(getContext(this) as common.UIAbilityContext);
      if (!this.current(sequence)) return;
      await this.process(this.selected, Date.now(), `import-${Date.now()}`, false, sequence, config, this.roi);
    } catch (error) {
      if (this.current(sequence)) this.status = `分析失败：${(error as Error).message}`;
    } finally {
      if (!this.disposed) this.updateAnalysisReport();
      this.busy = false;
    }
  }

  private async start(): Promise<void> {
    if (this.running || this.busy || this.transitioning) return;
    const sequence = ++this.sequence;
    this.starting = true;
    this.transitioning = true;
    try {
      const config = this.settings();
      const intervalMs = parseCaptureIntervalMs(this.intervalText);
      const context = getContext(this) as common.UIAbilityContext;
      this.status = '正在准备手机语音模型……';
      await LocalNeuralSpeech.prepare(context);
      if (!this.current(sequence)) return;
      this.report('请允许后台任务通知和系统录屏授权。');
      await notificationManager.requestEnableNotification();
      if (!this.current(sequence)) return;
      const state = await PhoneScreen.start(context, '', LIVE_CAPTURE_INTERVAL_MS);
      if (!this.current(sequence)) { await PhoneScreen.stop(); return; }
      if (!state.supported || ['denied', 'error', 'unsupported'].indexOf(state.state) >= 0) {
        throw new Error(state.error || `系统未提供所需API ${state.requiredApi}授权截屏接口，可改用导入截图`);
      }
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0, wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      if (!this.current(sequence)) return;
      await backgroundTaskManager.startBackgroundRunning(
        context, ['audioRecording', 'audioPlayback'], agent);
      this.backgroundRunning = true;
      if (!this.current(sequence)) {
        this.backgroundRunning = false;
        await backgroundTaskManager.stopBackgroundRunning(context);
        await PhoneScreen.stop();
        return;
      }
      this.config = config;
      this.runRoi = this.roi;
      this.runIntervalMs = intervalMs;
      this.nextAnalysisAt = 0;
      this.api.resetStats();
      this.analysisReport = '';
      this.running = true;
      this.selected = undefined;
      this.hasScreenshot = false;
      this.preview = '';
      this.previewCapturedAt = '';
      this.sourcePreview = '';
      this.reply = '';
      this.briefings.reset();
      this.lastId = '';
      this.consentAt = Date.now();
      this.lastFrameAt = this.consentAt;
      this.frameWaitMs = Math.max(30000, intervalMs * 2 + 5000);
      this.liveReport = '采集0帧，已播报0次。';
      this.imageIssue = '';
      this.report('后台录屏和播报任务已启动；允许录屏后切换到游戏，保持屏幕亮起。');
      this.schedule(sequence);
    } catch (error) {
      if (this.current(sequence)) {
        await this.stop();
        if (!this.disposed) this.report(`启动失败：${(error as Error).message}`);
      }
    } finally {
      this.starting = false;
      this.transitioning = this.stopping;
    }
  }

  private schedule(sequence: number): void {
    if (this.running && this.current(sequence)) this.timer = setTimeout(() => void this.tick(sequence), 500);
  }

  private async tick(sequence: number): Promise<void> {
    if (!this.running || !this.current(sequence) || this.busy) return;
    this.busy = true;
    try {
      const state = await PhoneScreen.status();
      if (!this.current(sequence)) return;
      this.liveReport = `采集${state.frames || 0}帧，已播报${this.count}次；${state.width || 0}×${state.height || 0}；` +
        `采集状态：${state.state}；随屏旋转：${state.canvasRotation && state.followRotation ? '已启用' : '未启用'}；` +
        `本机每秒取帧，云端至少间隔${this.runIntervalMs / 1000}秒。`;
      if (['denied', 'stopped', 'stopped_by_system', 'error', 'unsupported'].indexOf(state.state) >= 0) {
        throw new Error(state.error || '用户或系统已停止屏幕采集');
      }
      if (!state.authorized || state.state !== 'capturing') {
        this.lastFrameAt = Date.now();
        if (Date.now() - this.consentAt > 60000) throw new Error('系统录屏授权等待超时');
        this.status = '等待系统录屏授权，请在系统弹窗中允许。';
        return;
      }
      if (state.privateScene) {
        this.lastFrameAt = Date.now();
        this.status = '系统报告隐私画面，已暂停上传。';
        return;
      }
      if (Date.now() < this.nextAnalysisAt) return;
      const frame = await PhoneScreen.read(this.lastId);
      if (!this.current(sequence)) return;
      if (!frame) {
        if (state.error) throw new Error(`截图取帧失败：${state.error}`);
        if (Date.now() - this.lastFrameAt > this.frameWaitMs) {
          throw new Error('录屏已授权但长时间没有新截图，请检查录屏是否仍在运行、游戏是否限制采集。');
        }
        this.status = '录屏已授权，等待下一张游戏截图……';
        return;
      }
      this.lastFrameAt = Date.now();
      this.lastId = frame.id;
      await this.process(new Uint8Array(frame.bytes), frame.capturedAt, frame.id,
        true, sequence, this.config!, this.runRoi);
    } catch (error) {
      if (this.current(sequence)) {
        if (error instanceof CloudFrameExpiredError) {
          this.reply = '';
          this.report(`${error.message}；继续等待新画面，保持云端请求间隔。`);
        } else {
          await this.stop();
          if (!this.disposed) this.report(`已停止：${(error as Error).message}`);
        }
      }
    } finally {
      if (!this.disposed) this.updateAnalysisReport();
      this.busy = false;
      this.schedule(sequence);
    }
  }

  private async process(bytes: Uint8Array, capturedAt: number, frameId: string, live: boolean,
    sequence: number, config: CloudBattleConfig, roi: string): Promise<void> {
    const maxAgeMs = live ? LIVE_FRAME_MAX_AGE_MS : CLOUD_FRAME_MAX_AGE_MS;
    assertCloudFrameFresh(capturedAt, maxAgeMs);
    const current = await cropCloudMinimap(bytes, roi, capturedAt, frameId);
    if (!this.current(sequence)) return;
    this.showCrop(current);
    if (this.imageIssue) {
      this.reply = '';
      this.report(this.imageIssue);
      return;
    }
    assertCloudFrameFresh(capturedAt, maxAgeMs);
    if (live) {
      if (Date.now() < this.nextAnalysisAt) return;
      this.nextAnalysisAt = Date.now() + this.runIntervalMs;
    }
    this.reply = '';
    this.previewCapturedAt = live ? new Date(capturedAt).toTimeString().slice(0, 8) : '';
    this.report('正在向云端发送小地图……');
    const text = await this.api.analyze(config, current, live);
    if (!this.current(sequence)) return;
    if (live) {
      const state = await PhoneScreen.status();
      if (!this.current(sequence)) return;
      if (!state.authorized || state.state !== 'capturing' || state.privateScene) {
        throw new Error('当前屏幕采集已停止或处于隐私画面，取消本次播报');
      }
    }
    assertCloudFrameFresh(capturedAt, maxAgeMs);
    this.reply = text;
    if (live && !this.briefings.shouldSpeak(text, Date.now())) {
      this.report(quietBriefing(text) ? '本帧没有可靠的新提醒，保持安静，继续观察。' : '相同提醒刚播报过，继续观察新动向。');
      return;
    }
    this.report('已收到战况，正在用手机语音模型合成并播报……');
    await this.voice!.play({ frame_id: frameId, text: text, captured_at: capturedAt }, '', true,
      maxAgeMs, this.speechRate);
    if (!this.current(sequence)) return;
    if (live) this.briefings.didSpeak(text, Date.now());
    ++this.count;
    this.report(`第${this.count}条播报完成${live ? '，等待下一张截图。' : '；本次解说仅对应所选截图。'}`);
  }

  private async stop(): Promise<void> {
    ++this.sequence;
    this.running = false;
    this.config = undefined;
    this.briefings.reset();
    clearTimeout(this.timer);
    this.timer = -1;
    this.api.cancel();
    this.voice?.cancel();
    if (this.stopping) return;
    this.stopping = true;
    this.transitioning = true;
    try {
      await PhoneScreen.stop();
    } catch (_) {
      if (!this.disposed) this.captureReport = '停止系统采集失败，请从系统录屏提示中结束采集。';
    } finally {
      if (this.backgroundRunning) {
        this.backgroundRunning = false;
        try { await backgroundTaskManager.stopBackgroundRunning(getContext(this) as common.UIAbilityContext); }
        catch (_) { if (!this.disposed) this.captureReport = '后台任务停止失败，请退出应用。'; }
      }
      this.stopping = false;
      this.transitioning = this.starting;
      if (!this.disposed) this.status = '已停止，后续回复不会继续播报。';
    }
  }

  private editable(): boolean {
    return !this.running && !this.busy && !this.transitioning;
  }

  private async previewVoice(): Promise<void> {
    if (!this.editable()) return;
    this.busy = true;
    const sequence = ++this.sequence;
    try {
      this.status = '正在合成战况试听……';
      await this.voice!.play({ frame_id: 'speech-preview', text: SPEECH_PREVIEW }, '', true,
        CLOUD_FRAME_MAX_AGE_MS, this.speechRate);
      if (this.current(sequence)) this.status = '试听完成；这是一条示例，不是实际战况。';
    } catch (error) {
      if (this.current(sequence)) this.status = `试听失败：${(error as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  private cropChanged(): void {
    this.preview = '';
    this.previewCapturedAt = '';
    this.sourcePreview = '';
    this.imageIssue = '';
    this.saveCloudSettings();
  }

  private showCrop(cropped: CloudImage): void {
    this.preview = cropped.url;
    this.previewCapturedAt = '';
    this.sourcePreview = cropped.sourcePreview || '';
    this.imageIssue = cropped.issue || '';
    this.sourceAspectRatio = cropped.sourceAspectRatio || 16 / 9;
    this.cropBounds = cropped.cropBounds || [0, 0, 1, 1];
  }

  private useRecommendedCrop(): void {
    if (!this.editable()) return;
    this.roi = DEFAULT_MINIMAP_ROI;
    this.cropChanged();
    if (this.hasScreenshot) void this.previewScreenshot();
  }

  private adjustCrop(shift: number, grow: number): void {
    if (!this.editable()) return;
    try {
      const region = parseMinimapRoi(this.roi);
      region[2] = Math.max(0.02, Math.min(1, region[2] + grow));
      region[0] = Math.max(0, Math.min(1 - region[2], region[0] + shift));
      this.roi = region.map((value: number) => Number(value.toFixed(4))).join(',');
      this.cropChanged();
      if (this.hasScreenshot) void this.previewScreenshot();
    } catch (_) {
      this.status = '请先填写有效的小地图范围，或使用推荐范围。';
    }
  }

  private updateAnalysisReport(): void {
    const stats = this.api.stats();
    if (!stats.requests) { this.analysisReport = ''; return; }
    this.analysisReport = `本次云端请求${stats.requests}次，最近耗时${(stats.lastLatencyMs / 1000).toFixed(1)}秒。`;
    if (stats.usageResponses) {
      this.analysisReport += `已知输入${stats.inputTokens}、输出${stats.outputTokens} token` +
        `（${stats.usageResponses}次返回用量，不含未返回用量的请求）。`;
    } else this.analysisReport += '接口尚未返回token用量，实际计费以云平台为准。';
    const playbackAgeMs = this.voice?.lastPlaybackAgeMs;
    if (playbackAgeMs !== undefined) {
      this.analysisReport += `最近开播时画面已过${(playbackAgeMs / 1000).toFixed(1)}秒。`;
    }
  }

  build() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('TACTIC').fontSize(12).fontWeight(FontWeight.Medium).letterSpacing(3).fontColor('#737373')
          Text('战局助手').fontSize(20).fontWeight(FontWeight.Medium).fontColor('#171717')
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.pageIndex === 0 ? '开始' : '配置').fontSize(13).fontColor('#737373')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 }).backgroundColor('#ECECE9').borderRadius(20)
      }.width('100%').padding({ left: 26, right: 26, top: 20, bottom: 18 })
      Swiper(this.pager) {
        this.homePage()
        this.settingsPage()
      }.layoutWeight(1).loop(false).indicator(false).index(this.pageIndex)
        .onChange((index: number) => { this.pageIndex = index; })
      Row({ space: 10 }) {
        Circle().width(6).height(6).fill(this.pageIndex === 0 ? '#737373' : '#D4D4D4')
        Circle().width(6).height(6).fill(this.pageIndex === 1 ? '#737373' : '#D4D4D4')
      }.height(34).justifyContent(FlexAlign.Center).width('100%')
    }.width('100%').height('100%').backgroundColor('#F7F7F5')
  }

  @Builder
  private homePage() {
    Scroll() {
      Column({ space: 22 }) {
        Column({ space: 10 }) {
          Text('看见战局\n听见机会').fontSize(34).fontWeight(FontWeight.Medium)
            .fontColor('#171717').textAlign(TextAlign.Center).lineHeight(44)
          Text('只听关键的一句。').fontSize(14).fontColor('#737373')
        }.width('100%').margin({ top: 22 })
        Stack() {
          Circle().width(202).height(202).fill('#F7F7F5').stroke('#DDDDDA').strokeWidth(1)
          Button({ type: ButtonType.Circle }) {
            Column({ space: 9 }) {
              Text(this.running || this.busy || this.transitioning ? '停止' : '开始')
                .fontSize(30).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              Text(this.running ? '正在聆听战局' : this.busy || this.transitioning ? '取消当前任务' : '自动战况播报')
                .fontSize(12).fontColor('#C9C9C9')
            }
          }.width(176).height(176).backgroundColor('#171717')
            .onClick(() => {
              if (this.running || this.busy || this.transitioning) { void this.stop(); }
              else { void this.start(); }
            })
        }.width('100%').height(214)
        Column({ space: 12 }) {
          Button('＋  导入系统截图', { type: ButtonType.Normal }).width('100%').height(52)
            .fontSize(15).fontColor('#171717').backgroundColor('#FFFFFF').borderRadius(18)
            .border({ width: 1, color: '#E5E5E1' }).enabled(this.editable())
            .onClick(() => { void this.importScreenshot(); })
          Text('静态截图分析 · 导入后先确认裁剪').fontSize(12).fontColor('#898989')
          Text('滑动进入配置  →').fontSize(12).fontColor('#737373')
            .onClick(() => { this.pager.changeIndex(1, true); })
        }.width('100%')
        if (this.hasScreenshot && !this.running) {
          Column({ space: 12 }) {
            Row() {
              Text('截图分析').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#171717')
              Blank()
              Text('静态').fontSize(12).fontColor('#898989')
            }.width('100%')
            if (this.preview) {
              Image(this.preview).width(192).height(192).objectFit(ImageFit.Contain).borderRadius(12)
            }
            Button('分析这张截图并播报', { type: ButtonType.Normal }).width('100%').height(46)
              .fontSize(14).backgroundColor('#171717').fontColor('#FFFFFF').borderRadius(14)
              .enabled(this.editable() && this.preview.length > 0 && !this.imageIssue)
              .onClick(() => { void this.analyzeScreenshot(); })
            Text('仅解说所选截图，不代表此刻的实时战况。').fontSize(12).fontColor('#898989')
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)
        }
        Column({ space: 12 }) {
          Row({ space: 7 }) {
            Circle().width(6).height(6).fill(this.running ? '#171717' : '#B4B4B4')
            Text(this.running ? '播报已开启' : this.busy || this.transitioning ? '正在处理' : '准备就绪')
              .fontSize(12).fontColor('#737373')
            Blank()
            Text(`${this.count} 次播报`).fontSize(12).fontColor('#898989')
          }.width('100%')
          if (this.reply) {
            Text(this.reply).fontSize(22).fontWeight(FontWeight.Medium).lineHeight(32)
              .fontColor('#171717').width('100%')
          }
          Text(this.status).fontSize(13).fontColor('#737373').lineHeight(21).width('100%')
          if (this.liveReport) { Text(this.liveReport).fontSize(12).fontColor('#898989').width('100%') }
          if (this.analysisReport) { Text(this.analysisReport).fontSize(12).fontColor('#898989').lineHeight(19).width('100%') }
          if (this.imageIssue) {
            Text('未上传黑帧，也不会触发语音。配置页可对照原始帧检查。').fontSize(12).fontColor('#A04732')
          }
          if (this.settingsError) { Text(this.settingsError).fontSize(12).fontColor('#A04732') }
        }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(22)
      }.width('100%').padding({ left: 26, right: 26, bottom: 20 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  @Builder
  private settingsPage() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 8 }) {
          Text('按你的节奏').fontSize(30).fontWeight(FontWeight.Medium).fontColor('#171717')
          Text('修改即保存，下次打开自动恢复。').fontSize(13).fontColor('#737373')
          if (!this.editable()) { Text('停止当前任务后可修改配置。').fontSize(12).fontColor('#898989') }
          if (this.settingsError) { Text(this.settingsError).fontSize(12).fontColor('#A04732') }
        }.alignItems(HorizontalAlign.Start).width('100%').margin({ top: 14 })
        Column({ space: 14 }) {
          Text('云端连接').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#171717').width('100%')
          this.fieldLabel('接口 URL', 'OpenAI 兼容接口，使用与你的 Key 匹配的区域')
          TextInput({ text: this.endpoint, placeholder: 'https://…/compatible-mode/v1' })
            .height(48).fontSize(13).backgroundColor('#F2F2EF').borderRadius(13).enabled(this.editable())
            .onChange((value: string) => { this.endpoint = value; this.saveCloudSettings(); })
          this.fieldLabel('API Key', '仅保存在本机，输入内容已隐藏')
          TextInput({ text: this.apiKey, placeholder: '输入 API Key' }).type(InputType.Password)
            .height(48).fontSize(14).backgroundColor('#F2F2EF').borderRadius(13).enabled(this.editable())
            .onChange((value: string) => { this.apiKey = value; this.saveCloudSettings(); })
          this.fieldLabel('视觉模型', '使用平台实际提供、支持图片输入的模型 ID')
          TextInput({ text: this.model, placeholder: 'qwen3.6-flash' })
            .height(48).fontSize(14).backgroundColor('#F2F2EF').borderRadius(13).enabled(this.editable())
            .onChange((value: string) => { this.model = value; this.saveCloudSettings(); })
        }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(22)
        Column({ space: 14 }) {
          Text('语音播报').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#171717').width('100%')
          this.fieldLabel('播报语速', '离线中文女声 · 默认均衡，优先吐字清晰')
          Select([{ value: '清晰 · 1.00 倍' }, { value: '均衡 · 1.08 倍' }, { value: '利落 · 1.18 倍' }])
            .selected(this.speechRate === 1.0 ? 0 : this.speechRate === 1.18 ? 2 : 1)
            .value(this.speechRate === 1.0 ? '清晰 · 1.00 倍' : this.speechRate === 1.18 ? '利落 · 1.18 倍' : '均衡 · 1.08 倍')
            .font({ size: 14 }).fontColor('#171717').backgroundColor('#F2F2EF').borderRadius(13)
            .width('100%').height(48).enabled(this.editable())
            .onSelect((index: number) => {
              this.speechRate = index === 0 ? 1.0 : index === 2 ? 1.18 : DEFAULT_SPEECH_RATE;
              this.saveCloudSettings();
            })
          Button('试听战况语音', { type: ButtonType.Normal }).width('100%').height(44)
            .backgroundColor('#F2F2EF').fontColor('#171717').fontSize(13).borderRadius(13)
            .enabled(this.editable()).onClick(() => { void this.previewVoice(); })
          Text('试听内容为示例，不上传图片。自动播报略过无明确动向和不清晰的判断，相同提醒至少间隔 20 秒。')
            .fontSize(12).fontColor('#898989').lineHeight(19)
        }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(22)
        Column({ space: 14 }) {
          Text('采集与识别').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#171717').width('100%')
          this.fieldLabel('云端分析间隔 · 秒', '1–300 秒；默认 10 秒，约每分钟最多 6 次；本机每秒更新截图')
          TextInput({ text: this.intervalText, placeholder: '10' }).type(InputType.Number)
            .height(48).fontSize(14).backgroundColor('#F2F2EF').borderRadius(13).enabled(this.editable())
            .onChange((value: string) => { this.intervalText = value; this.saveCloudSettings(); })
          Text('缩短分析间隔会增加云端调用。每次只发一张最新小地图；开播前超过 8 秒的画面直接跳过。')
            .fontSize(12).fontColor('#898989').lineHeight(19)
          this.fieldLabel('我方英雄标记边框', '看头像边缘红蓝环，不看头像本身颜色；灰色是血量变化，未校准只做中性报点')
          Select([{ value: '未校准' }, { value: '蓝色是我方' }, { value: '红色是我方' }])
            .selected(this.allyColor === 'blue' ? 1 : this.allyColor === 'red' ? 2 : 0)
            .value(this.allyColor === 'blue' ? '蓝色是我方' : this.allyColor === 'red' ? '红色是我方' : '未校准')
            .font({ size: 14 }).fontColor('#171717').backgroundColor('#F2F2EF').borderRadius(13)
            .width('100%').height(48).enabled(this.editable())
            .onSelect((index: number) => {
              this.allyColor = index === 1 ? 'blue' : index === 2 ? 'red' : 'unknown';
              this.saveCloudSettings();
            })
          this.fieldLabel('小地图范围', '左边距,上边距,宽,高 · 均为画面 0–1 比例')
          TextInput({ text: this.roi, placeholder: DEFAULT_MINIMAP_ROI })
            .height(48).fontSize(14).backgroundColor('#F2F2EF').borderRadius(13).enabled(this.editable())
            .onChange((value: string) => { this.roi = value; this.cropChanged(); })
          Button('使用当前横屏布局推荐范围', { type: ButtonType.Normal }).width('100%').height(42)
            .backgroundColor('#F2F2EF').fontColor('#171717').fontSize(13).borderRadius(13)
            .enabled(this.editable()).onClick(() => { this.useRecommendedCrop(); })
          Row({ space: 6 }) {
            Button('左移').layoutWeight(1).fontSize(12).height(38).padding({ left: 0, right: 0 }).backgroundColor('#F2F2EF').fontColor('#171717')
              .enabled(this.editable()).onClick(() => { this.adjustCrop(-0.005, 0); })
            Button('右移').layoutWeight(1).fontSize(12).height(38).padding({ left: 0, right: 0 }).backgroundColor('#F2F2EF').fontColor('#171717')
              .enabled(this.editable()).onClick(() => { this.adjustCrop(0.005, 0); })
            Button('收窄').layoutWeight(1).fontSize(12).height(38).padding({ left: 0, right: 0 }).backgroundColor('#F2F2EF').fontColor('#171717')
              .enabled(this.editable()).onClick(() => { this.adjustCrop(0, -0.005); })
            Button('加宽').layoutWeight(1).fontSize(12).height(38).padding({ left: 0, right: 0 }).backgroundColor('#F2F2EF').fontColor('#171717')
              .enabled(this.editable()).onClick(() => { this.adjustCrop(0, 0.005); })
          }.width('100%')
          Text('保持地图原始宽高比，完整上传白框选区，无需限制为方形。').fontSize(12).fontColor('#898989')
          Text('按原图坐标裁剪，不自动改动图片方向或范围。自动录屏会随设备旋转；请先用静态截图校准小地图。')
            .fontSize(12).fontColor('#898989').lineHeight(19)
          if (this.hasScreenshot) {
            Button('刷新所选截图的裁剪预览', { type: ButtonType.Normal }).width('100%').height(44)
              .backgroundColor('#F2F2EF').fontColor('#171717').fontSize(13).borderRadius(13)
              .enabled(this.editable()).onClick(() => { void this.previewScreenshot(); })
          }
        }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(22)
        if (this.sourcePreview || this.preview) {
          Column({ space: 12 }) {
            Text('采集检查 · 仅在手机预览').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#171717').width('100%')
            if (this.sourcePreview) {
              Text('原始帧 · 白框为实际选区，不上传整图').fontSize(12).fontColor('#737373').width('100%')
              Stack({ alignContent: Alignment.TopStart }) {
                Image(this.sourcePreview).width('100%').height('100%').objectFit(ImageFit.Contain)
                Rect().width(`${this.cropBounds[2] * 100}%`).height(`${this.cropBounds[3] * 100}%`)
                  .position({ x: `${this.cropBounds[0] * 100}%`, y: `${this.cropBounds[1] * 100}%` })
                  .fill(Color.Transparent).stroke('#FFFFFF').strokeWidth(2)
              }.width('100%').aspectRatio(this.sourceAspectRatio).backgroundColor('#ECECE9')
            }
            if (this.preview) {
              Text(this.imageIssue ? '裁剪图 · 已拦截上传' : '实际发送的小地图').fontSize(12).fontColor('#737373').width('100%')
              if (this.previewCapturedAt) {
                Text(`分析帧采集于 ${this.previewCapturedAt}`).fontSize(12).fontColor('#737373').width('100%')
              }
              Image(this.preview).width(210).height(210).objectFit(ImageFit.Contain).backgroundColor('#ECECE9')
            }
            if (this.imageIssue) { Text(this.imageIssue).fontSize(12).fontColor('#A04732').lineHeight(20) }
          }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(22)
        }
        Column({ space: 10 }) {
          Text('运行状态').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#171717').width('100%')
          Text(this.captureReport).fontSize(12).fontColor('#737373').lineHeight(20).width('100%')
          Text('允许系统录屏时请选择整个屏幕。开启后切到游戏并保持屏幕亮起；全黑帧会跳过，继续等待下一帧。')
            .fontSize(12).fontColor('#898989').lineHeight(20)
        }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(22)
      }.width('100%').padding({ left: 26, right: 26, bottom: 20 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }

  @Builder
  private fieldLabel(title: string, note: string) {
    Column({ space: 5 }) {
      Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#404040')
      Text(note).fontSize(11).fontColor('#898989').lineHeight(17)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
}
