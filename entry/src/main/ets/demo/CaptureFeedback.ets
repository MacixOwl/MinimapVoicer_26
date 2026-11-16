import promptAction from '@ohos.promptAction';
import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import { PhoneScreen } from './PhoneScreen';
import { CaptureFeedbackGate, CAPTURE_FEEDBACK_DURATION_MS, CAPTURE_FEEDBACK_MIN_GAP_MS } from './CaptureFeedbackPolicy';

const NOTIFICATION_ID: number = 48321;
const NOTIFICATION_LABEL: string = 'capture-debug';

// Separate from model/TTS scheduling: only native, successfully saved frames count.
export class CaptureFeedback {
  private static enabled: boolean = false;
  private static active: boolean = false;
  private static foreground: boolean = true;
  private static notificationReady: boolean = false;
  private static notificationProblem: string = '尚未申请通知授权';
  private static timer: number = -1;
  private static cleanupTimer: number = -1;
  private static epoch: number = 0;
  private static permissionEpoch: number = 0;
  private static busy: boolean = false;
  private static displaying: boolean = false;
  private static lastSimulatedNotice: number = -Infinity;
  private static gate: CaptureFeedbackGate = new CaptureFeedbackGate();

  private static report(text: string): void {
    AppStorage.SetOrCreate('captureFeedbackStatus', text);
    console.info(`GameVoice capture feedback: ${text}`);
  }

  static setForeground(value: boolean): void {
    CaptureFeedback.foreground = value;
  }

  static async setEnabled(value: boolean): Promise<void> {
    CaptureFeedback.enabled = value;
    AppStorage.SetOrCreate('captureFeedbackEnabled', value);
    const permissionEpoch = ++CaptureFeedback.permissionEpoch;
    CaptureFeedback.restartMonitor();
    if (!value) {
      await CaptureFeedback.cancelNotice();
      if (!CaptureFeedback.enabled && permissionEpoch === CaptureFeedback.permissionEpoch) CaptureFeedback.report('截图反馈已关闭。');
      return;
    }
    CaptureFeedback.report('截图反馈已开启，正在申请系统通知授权；前台使用短提示。');
    CaptureFeedback.notificationReady = false;
    try {
      await notificationManager.requestEnableNotification();
      if (!CaptureFeedback.enabled || permissionEpoch !== CaptureFeedback.permissionEpoch) return;
      await notificationManager.addSlot(notificationManager.SlotType.OTHER_TYPES);
      if (!CaptureFeedback.enabled || permissionEpoch !== CaptureFeedback.permissionEpoch) return;
      CaptureFeedback.notificationReady = true;
      CaptureFeedback.notificationProblem = '';
      CaptureFeedback.report('截图反馈已开启：前台短提示，后台临时通知。游戏横幅需在系统通知设置允许。');
    } catch (error) {
      if (!CaptureFeedback.enabled || permissionEpoch !== CaptureFeedback.permissionEpoch) return;
      CaptureFeedback.notificationReady = false;
      CaptureFeedback.notificationProblem = (error as Error).message || String(error);
      CaptureFeedback.report(`前台短提示可用，后台通知未就绪：${CaptureFeedback.notificationProblem}`);
    }
  }

  static async showSimulatedFrame(): Promise<void> {
    const now = Date.now();
    if (!CaptureFeedback.enabled || now - CaptureFeedback.lastSimulatedNotice < CAPTURE_FEEDBACK_MIN_GAP_MS) return;
    CaptureFeedback.lastSimulatedNotice = now;
    await CaptureFeedback.show('模拟截图已就绪（样例画面）', CaptureFeedback.epoch);
  }

  static begin(): void {
    CaptureFeedback.active = true;
    CaptureFeedback.restartMonitor();
  }

  static async stop(): Promise<void> {
    CaptureFeedback.active = false;
    CaptureFeedback.restartMonitor();
    await CaptureFeedback.cancelNotice();
  }

  private static restartMonitor(): void {
    ++CaptureFeedback.epoch;
    clearInterval(CaptureFeedback.timer);
    CaptureFeedback.timer = -1;
    CaptureFeedback.gate.reset();
    if (!CaptureFeedback.active || !CaptureFeedback.enabled) return;
    const epoch = CaptureFeedback.epoch;
    // Establish a baseline when enabling midway; never announce an old frame.
    let baseline: boolean = true;
    CaptureFeedback.timer = setInterval(() => {
      if (CaptureFeedback.busy || epoch !== CaptureFeedback.epoch) return;
      const prime = baseline;
      baseline = false;
      void CaptureFeedback.poll(epoch, prime);
    }, 500);
  }

  private static async poll(epoch: number, baseline: boolean): Promise<void> {
    CaptureFeedback.busy = true;
    try {
      const frame = await PhoneScreen.status();
      if (epoch !== CaptureFeedback.epoch || !CaptureFeedback.active || !CaptureFeedback.enabled) return;
      if (baseline) {
        CaptureFeedback.gate.reset(frame.frameId);
        return;
      }
      if (['denied', 'stopped_by_system', 'stopped', 'error', 'unsupported'].indexOf(frame.state) >= 0) {
        await CaptureFeedback.stop();
        return;
      }
      const text = CaptureFeedback.gate.inspect(frame, CaptureFeedback.enabled, Date.now());
      if (text) await CaptureFeedback.show(text, epoch);
    } catch (error) {
      if (epoch === CaptureFeedback.epoch) CaptureFeedback.report(`截图反馈读取失败：${(error as Error).message}`);
    } finally {
      CaptureFeedback.busy = false;
    }
  }

  static async test(): Promise<void> {
    if (!CaptureFeedback.enabled) {
      CaptureFeedback.report('请先开启“截图成功提示”。');
      return;
    }
    // Test messages must not be confused with native capture success.
    try {
      await CaptureFeedback.show('截图反馈测试（未截图）', CaptureFeedback.epoch, true);
    } catch (error) {
      CaptureFeedback.report(`测试提示失败：${(error as Error).message}`);
    }
  }

  private static async show(text: string, epoch: number, test: boolean = false): Promise<void> {
    if (CaptureFeedback.displaying) return;
    CaptureFeedback.displaying = true;
    try {
      await CaptureFeedback.showNow(text, epoch, test);
    } finally {
      CaptureFeedback.displaying = false;
    }
  }

  private static async showNow(text: string, epoch: number, test: boolean): Promise<void> {
    if (!CaptureFeedback.enabled || epoch !== CaptureFeedback.epoch) return;
    if (CaptureFeedback.foreground && !test) {
      try {
        promptAction.showToast({ message: text, duration: CAPTURE_FEEDBACK_DURATION_MS });
        CaptureFeedback.report(`最近反馈：${text}（前台短提示）。`);
      } catch (error) {
        CaptureFeedback.report(`截图已成功，短提示显示失败：${(error as Error).message}`);
      }
      return;
    }
    if (test && CaptureFeedback.foreground) {
      promptAction.showToast({ message: text, duration: CAPTURE_FEEDBACK_DURATION_MS });
    }
    if (!CaptureFeedback.notificationReady) {
      CaptureFeedback.report(`${text}；后台通知未就绪：${CaptureFeedback.notificationProblem}`);
      return;
    }
    const now = Date.now();
    try {
      clearTimeout(CaptureFeedback.cleanupTimer);
      await notificationManager.publish({
        id: NOTIFICATION_ID, label: NOTIFICATION_LABEL,
        slotType: notification.SlotType.OTHER_TYPES,
        isOngoing: false, isUnremovable: false, isAlertOnce: false,
        showDeliveryTime: false, autoDeletedTime: now + CAPTURE_FEEDBACK_DURATION_MS,
        distributedOption: { isDistributed: false },
        content: {
          contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: test ? '截图提示测试' : '战场语音 · 截图反馈', text: text }
        }
      });
      if (!CaptureFeedback.enabled || epoch !== CaptureFeedback.epoch) {
        await CaptureFeedback.cancelNotice();
        return;
      }
      clearTimeout(CaptureFeedback.cleanupTimer);
      CaptureFeedback.cleanupTimer = setTimeout(() => {
        if (epoch === CaptureFeedback.epoch) void CaptureFeedback.cancelNotice();
      }, CAPTURE_FEEDBACK_DURATION_MS);
      CaptureFeedback.report(`${text}；已提交临时通知，横幅显示由系统设置决定。`);
    } catch (error) {
      if (epoch === CaptureFeedback.epoch) CaptureFeedback.report(`${text}；通知发送失败：${(error as Error).message}`);
    }
  }

  private static async cancelNotice(): Promise<void> {
    clearTimeout(CaptureFeedback.cleanupTimer);
    CaptureFeedback.cleanupTimer = -1;
    try {
      await notificationManager.cancel(NOTIFICATION_ID, NOTIFICATION_LABEL);
    } catch (_) {
      // No pending debug notification is a normal state.
    }
  }
}
