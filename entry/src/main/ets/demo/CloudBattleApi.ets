import http from '@ohos.net.http';
import { CloudImage } from './CloudImages';
import { cloudBattlePrompt } from './GamePrompt';
import { spokenBriefing } from './BattleBriefing';
import { CLOUD_FRAME_MAX_AGE_MS, LIVE_FRAME_MAX_AGE_MS, CloudFrameExpiredError,
  assertCloudFrameFresh, liveRequestBudgetMs } from './CloudTiming';

export interface CloudBattleConfig {
  endpoint: string;
  apiKey: string;
  model: string;
  allyColor?: string;
}

interface CloudImageUrl {
  url: string;
}

interface CloudContentPart {
  type: string;
  text?: string;
  image_url?: CloudImageUrl;
}

interface CloudResponseMessage {
  content?: string;
}

interface CloudChatChoice {
  finish_reason?: string;
  message?: CloudResponseMessage;
}

interface CloudChatReply {
  choices?: CloudChatChoice[];
  usage?: CloudTokenUsage;
}

interface CloudTokenUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
}

export interface CloudAnalysisStats {
  requests: number;
  inputTokens: number;
  outputTokens: number;
  usageResponses: number;
  lastLatencyMs: number;
}

interface CloudChatMessage {
  role: string;
  content: string | CloudContentPart[];
}

interface CloudChatRequest {
  model: string;
  temperature: number;
  stream: boolean;
  max_tokens: number;
  enable_thinking: boolean;
  messages: CloudChatMessage[];
}

export function cloudChatUrl(endpoint: string): string {
  const value = endpoint.trim().replace(/\/+$/, '');
  if (!/^https:\/\/[a-zA-Z0-9.-]+(?::\d{1,5})?(?:\/[a-zA-Z0-9._~!$&'()*+,;=:@%/-]*)?$/.test(value)) {
    throw new Error('请填写HTTPS云端地址，不包含密钥、查询参数或账号密码');
  }
  if (value.indexOf('/api/v1/services/') >= 0) throw new Error('请使用云平台提供的OpenAI兼容接口地址');
  if (value.endsWith('/chat/completions')) return value;
  return value + (/\/v\d+$/.test(value) ? '' : '/v1') + '/chat/completions';
}

export function validateCloudConfig(config: CloudBattleConfig): void {
  cloudChatUrl(config.endpoint);
  if (!config.apiKey.trim() || /\s/.test(config.apiKey.trim())) throw new Error('请填写有效的API Key');
  if (!config.model.trim() || config.model.trim().length > 128 || /\s/.test(config.model.trim())) {
    throw new Error('请填写平台实际提供的视觉模型ID');
  }
  if (config.allyColor !== undefined && ['unknown', 'blue', 'red'].indexOf(config.allyColor) < 0) {
    throw new Error('请选择有效的敌我配色校准');
  }
}

export function normalizeCloudBriefing(raw: string): string {
  if (typeof raw !== 'string' || raw.length > 4096) throw new Error('云端未返回有效文本');
  const text = raw.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
  if (!text || !/[\u3400-\u9fff]/.test(text) || Array.from(text).length > 24 ||
    /[\r\n#*_`|<>{}\[\]]/.test(text) || /https?:\/\//i.test(text)) {
    throw new Error('云端回复不是简短中文战况，请检查模型和接口配置');
  }
  if (/小兵|兵线|红点|红色单位|红色标记|录屏|录制|计时器|麦克风|状态栏|悬浮窗|悬浮球|疑似英雄|可能是英雄|消失|转线|正在支援|正在交战|逼近/.test(text)) {
    return '画面不清，暂不判断。';
  }
  const spoken = spokenBriefing(text);
  if (Array.from(spoken).length > 24) throw new Error('云端回复不是简短中文战况，请检查模型和接口配置');
  return spoken;
}

export class CloudBattleApi {
  private pending: http.HttpRequest | undefined;
  private generation: number = 0;
  private requests: number = 0;
  private inputTokens: number = 0;
  private outputTokens: number = 0;
  private usageResponses: number = 0;
  private lastLatencyMs: number = 0;

  resetStats(): void {
    this.requests = 0;
    this.inputTokens = 0;
    this.outputTokens = 0;
    this.usageResponses = 0;
    this.lastLatencyMs = 0;
  }

  stats(): CloudAnalysisStats {
    return { requests: this.requests, inputTokens: this.inputTokens, outputTokens: this.outputTokens,
      usageResponses: this.usageResponses, lastLatencyMs: this.lastLatencyMs };
  }

  cancel(): void {
    ++this.generation;
    this.pending?.destroy();
    this.pending = undefined;
  }

  async analyze(config: CloudBattleConfig, current: CloudImage, live: boolean = false): Promise<string> {
    validateCloudConfig(config);
    const maxAgeMs = live ? LIVE_FRAME_MAX_AGE_MS : CLOUD_FRAME_MAX_AGE_MS;
    assertCloudFrameFresh(current.capturedAt, maxAgeMs);
    if (current.issue) throw new Error(current.issue);
    if (this.pending) throw new Error('上一条云端请求尚未完成');
    const generation = this.generation;
    const content: CloudContentPart[] = [];
    content.push({ type: 'text', text: '当前小地图：忽略录屏红点、状态栏和小兵，再逐个确认地图内英雄；以剩余红蓝弧段判敌我，不看头像本身颜色。灰色环段只辅助判断血量；只报最紧急的可见风险，没有证据不凑人数或地点，单帧不报消失。' });
    content.push({ type: 'image_url', image_url: { url: current.url } });
    const body: CloudChatRequest = {
      model: config.model.trim(), temperature: 0.1, stream: false, max_tokens: 96, enable_thinking: false,
      messages: [{ role: 'system', content: cloudBattlePrompt(config.allyColor) }, { role: 'user', content: content }]
    };
    const budgetMs = live ? liveRequestBudgetMs(current.capturedAt) : 18000;
    const request = http.createHttp();
    this.pending = request;
    const startedAt = Date.now();
    ++this.requests;
    let deadline: number = -1;
    try {
      let response: http.HttpResponse;
      try {
        const pending = request.request(cloudChatUrl(config.endpoint), {
          method: http.RequestMethod.POST,
          header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${config.apiKey.trim()}` },
          extraData: JSON.stringify(body),
          connectTimeout: live ? Math.min(3000, budgetMs) : 8000,
          readTimeout: budgetMs, expectDataType: http.HttpDataType.STRING
        });
        response = live ? await Promise.race<http.HttpResponse>([pending,
          new Promise<http.HttpResponse>((resolve, reject) => {
            deadline = setTimeout(() => {
              reject(new CloudFrameExpiredError('云端回复超过实时预算，已跳过旧画面；本次请求仍可能计费'));
              request.destroy();
            }, budgetMs);
          })]) : await pending;
      } catch (error) {
        if (error instanceof CloudFrameExpiredError) throw error;
        if (generation !== this.generation) throw new Error('云端请求已取消');
        if (live && Date.now() - startedAt >= budgetMs - 100) {
          throw new CloudFrameExpiredError('云端回复超过实时预算，跳过旧画面；本次请求仍可能计费');
        }
        throw new Error('云端连接失败或超时，请检查网络和接口地址');
      }
      if (generation !== this.generation) throw new Error('云端请求已取消');
      if (response.responseCode !== 200) {
        const hints: Map<number, string> = new Map<number, string>([
          [400, '检查模型是否支持图像输入及接口格式'], [401, '检查API Key'], [403, '检查模型权限或额度'],
          [404, '检查接口地址与模型ID'], [429, '请求限流或额度不足，请稍后再试']
        ]);
        throw new Error(`云端HTTP ${response.responseCode}：${hints.get(response.responseCode) ?? '服务暂不可用'}`);
      }
      if (typeof response.result !== 'string' || response.result.length > 262144) {
        throw new Error('云端响应格式错误或过大');
      }
      let result: CloudChatReply;
      try { result = JSON.parse(response.result) as CloudChatReply; }
      catch (_) { throw new Error('云端未返回有效JSON'); }
      const input = result?.usage?.prompt_tokens;
      const output = result?.usage?.completion_tokens;
      if (typeof input === 'number' && typeof output === 'number' &&
        Number.isSafeInteger(input) && input >= 0 && Number.isSafeInteger(output) && output >= 0) {
        this.inputTokens += input;
        this.outputTokens += output;
        ++this.usageResponses;
      }
      const choice = result?.choices?.[0];
      if (choice?.finish_reason === 'length') throw new Error('云端回复被截断，跳过播报');
      let text = normalizeCloudBriefing(choice?.message?.content ?? '');
      if ((!config.allyColor || config.allyColor === 'unknown') && /敌|我方|队友|友军/.test(text)) {
        text = '画面不清，暂不判断。';
      }
      assertCloudFrameFresh(current.capturedAt, maxAgeMs);
      return text;
    } finally {
      clearTimeout(deadline);
      this.lastLatencyMs = Math.max(0, Date.now() - startedAt);
      request.destroy();
      if (this.pending === request) this.pending = undefined;
    }
  }
}
