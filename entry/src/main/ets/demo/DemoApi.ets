import http from '@ohos.net.http';
import util from '@ohos.util';
import image from '@ohos.multimedia.image';
import { Frame } from './FrameSource';
import { GAME_SYSTEM_PROMPT, MINIMAP_SYSTEM_PROMPT } from './GamePrompt';
import { normalizeBroadcast, TEST_BROADCAST } from './BroadcastPolicy';
import { MinimapTracker, MAP_MAX_AGE_MS, parseMapObservation, parseMinimapRoi } from './MinimapTracker';
import { ROCKCHIP_MOCK_ONLY, ROCKCHIP_MOCK_REPLY } from './DemoMode';

export const DEMO_TEXT: string = TEST_BROADCAST;

export interface DemoReply {
  frame_id: string;
  text: string;
  audio_base64?: string;
  analysis_status?: string;
  minimap_preview?: string;
  captured_at?: number;
}

interface FrameReply {
  frame_id: string;
  mime: string;
  image_base64: string;
}

interface ChatResponseMessage {
  content: string;
}

interface ChatChoice {
  message: ChatResponseMessage;
}

interface ChatReply {
  choices: ChatChoice[];
}

interface ChatImageUrl {
  url: string;
}

interface ChatContent {
  type: string;
  text?: string;
  image_url?: ChatImageUrl;
}

interface ChatMessage {
  role: string;
  content: string | ChatContent[];
}

interface ChatRouting {
  mode: string;
}

interface ChatExtraBody {
  routing: ChatRouting;
}

interface ChatRequest {
  model: string;
  stream: boolean;
  max_tokens: number;
  temperature: number;
  enable_thinking: boolean;
  extra_body: ChatExtraBody;
  messages: ChatMessage[];
}

export class DemoApi {
  private pending: http.HttpRequest | undefined;
  private tracker: MinimapTracker = new MinimapTracker();
  private generation: number = 0;

  resetTemporal(): void {
    ++this.generation;
    this.tracker.reset();
  }

  cancel(): void {
    const request = this.pending;
    this.pending = undefined;
    request?.destroy();
  }

  async analyze(origin: string, frame: Frame, frameId: string): Promise<DemoReply | undefined> {
    const body = JSON.stringify({
      frame_id: frameId,
      source: 'hap',
      mime: frame.mime,
      image_base64: new util.Base64Helper().encodeToStringSync(frame.bytes)
    });
    return this.send(`${origin}/analyze`, http.RequestMethod.POST, body);
  }

  async latest(origin: string, after: string): Promise<DemoReply | undefined> {
    return this.send(`${origin}/latest?after=${encodeURIComponent(after)}`, http.RequestMethod.GET);
  }

  async latestFrame(origin: string, after: string): Promise<FrameReply | undefined> {
    const response = await this.raw(`${origin}/latest-frame?after=${encodeURIComponent(after)}`, http.RequestMethod.GET);
    if (!response) {
      return undefined;
    }
    const frame = JSON.parse(response) as FrameReply;
    if (!frame.frame_id || !frame.image_base64 || !/^image\/(png|jpeg)$/.test(frame.mime)) {
      throw new Error('USB 中继未返回有效图像');
    }
    return frame;
  }

  async infer(origin: string, frame: Frame, frameId: string, peer: boolean,
    roi: string = '', capturedAt: number = Date.now()): Promise<DemoReply> {
    if (ROCKCHIP_MOCK_ONLY && (!peer || roi)) {
      throw new Error('当前版本仅支持瑞芯微模拟转发，不执行视觉分析。');
    }
    if (roi) return this.inferMinimap(origin, frame, frameId, peer, roi, capturedAt);
    const resized = await this.resize(frame);
    const encoded = new util.Base64Helper().encodeToStringSync(resized.bytes);
    return this.chat(origin, encoded, resized.mime, frameId, peer);
  }

  async inferEncoded(origin: string, encoded: string, mime: string, frameId: string, peer: boolean,
    roi: string = '', capturedAt: number = Date.now()): Promise<DemoReply> {
    return this.infer(origin, new Frame(new util.Base64Helper().decodeSync(encoded), mime), frameId, peer,
      roi, capturedAt);
  }

  private async inferMinimap(origin: string, frame: Frame, frameId: string, peer: boolean,
    roi: string, capturedAt: number): Promise<DemoReply> {
    const generation = this.generation;
    if (Date.now() - capturedAt > MAP_MAX_AGE_MS) {
      this.tracker.reset();
      return { frame_id: frameId, text: '', analysis_status: '图像已过期，等待新截图。' };
    }
    const region = parseMinimapRoi(roi);
    const bytes = frame.bytes;
    const source = image.createImageSource(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    const packer = image.createImagePacker();
    let pixels: image.PixelMap | undefined;
    let encoded: string;
    let geometry: string;
    try {
      const size = (await source.getImageInfo()).size;
      const width = Math.floor(size.width * region[2]);
      const height = Math.floor(size.height * region[3]);
      if (width < 64 || height < 64) {
        this.tracker.reset();
        return { frame_id: frameId, text: '',
          analysis_status: '小地图裁剪不足64像素，请使用游戏截图并校准范围；样例图可选单帧提醒。' };
      }
      pixels = await source.createPixelMap({ desiredRegion: {
        x: Math.floor(size.width * region[0]), y: Math.floor(size.height * region[1]),
        size: { width: width, height: height }
      } });
      // Downscale only. Enlarging a tiny minimap does not recover its detail.
      const scale = Math.min(1, 320 / Math.max(width, height));
      if (scale < 1) await pixels.scale(scale, scale);
      const packed = new Uint8Array(await packer.packing(pixels, { format: 'image/jpeg', quality: 90 }));
      encoded = new util.Base64Helper().encodeToStringSync(packed);
      geometry = `${size.width}x${size.height}:${region.join(',')}:${origin}:${peer}`;
    } finally {
      await pixels?.release();
      await source.release();
      await packer.release();
    }
    const request: ChatRequest = {
      model: 'qwen3.5-0.8b-gguf', stream: false, max_tokens: 96,
      temperature: 0, enable_thinking: false,
      extra_body: { routing: { mode: peer ? 'peer_preferred' : 'local_only' } },
      messages: [
        { role: 'system', content: MINIMAP_SYSTEM_PROMPT },
        { role: 'user', content: [
          { type: 'text', text: '只报告这张裁剪图的当前观测JSON。' },
          { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${encoded}` } }
        ] }
      ]
    };
    const body = JSON.stringify(request);
    try {
      const response = await this.raw(`${origin}/v1/chat/completions`, http.RequestMethod.POST, body, 15000);
      if (generation !== this.generation) return { frame_id: frameId, text: '' };
      const chat = response ? JSON.parse(response) as ChatReply : undefined;
      const observation = parseMapObservation(chat?.choices?.[0]?.message?.content ?? '');
      const decision = this.tracker.observe(observation, capturedAt, Date.now(), geometry);
      return { frame_id: frameId, text: decision.text ? normalizeBroadcast(decision.text) : '',
        analysis_status: decision.status, minimap_preview: `data:image/jpeg;base64,${encoded}`,
        captured_at: capturedAt };
    } catch (error) {
      if (generation === this.generation) this.tracker.reset();
      throw error as Error;
    }
  }

  private async resize(frame: Frame): Promise<Frame> {
    const bytes = frame.bytes;
    const source = image.createImageSource(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    let pixels: image.PixelMap | undefined;
    const packer = image.createImagePacker();
    try {
      const info = await source.getImageInfo();
      const scale = Math.min(1, 640 / Math.max(info.size.width, info.size.height));
      if (scale === 1) {
        return frame;
      }
      pixels = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(info.size.width * scale)),
        height: Math.max(1, Math.round(info.size.height * scale))
      } });
      return new Frame(new Uint8Array(await packer.packing(pixels, {
        format: 'image/jpeg', quality: 70
      })), 'image/jpeg');
    } finally {
      await pixels?.release();
      await source.release();
      await packer.release();
    }
  }

  private async chat(origin: string, encoded: string, mime: string, frameId: string, peer: boolean): Promise<DemoReply> {
    const request: ChatRequest = {
      model: 'qwen3.5-0.8b-gguf',
      stream: false,
      max_tokens: 64,
      temperature: 0,
      enable_thinking: false,
      extra_body: { routing: { mode: peer ? 'peer_preferred' : 'local_only' } },
      messages: [
        { role: 'system', content: GAME_SYSTEM_PROMPT },
        { role: 'user', content: [
          { type: 'text', text: '请根据当前画面给出一句提醒。' },
          { type: 'image_url', image_url: { url: `data:${mime};base64,${encoded}` } }
        ] }
      ]
    };
    const body = JSON.stringify(request);
    const response = await this.raw(`${origin}/v1/chat/completions`, http.RequestMethod.POST, body);
    if (!response) {
      throw new Error('SmartServe 未返回推理结果');
    }
    const chat = JSON.parse(response) as ChatReply;
    const content = chat.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || !content.trim()) {
      throw new Error('模型未生成解说文本');
    }
    if (ROCKCHIP_MOCK_ONLY && content !== ROCKCHIP_MOCK_REPLY) {
      throw new Error('后端未返回约定的模拟文本，请确认连接的是瑞芯微模拟服务。');
    }
    const text = normalizeBroadcast(content);
    return { frame_id: frameId, text: text };
  }

  private async send(url: string, method: http.RequestMethod, body?: string): Promise<DemoReply | undefined> {
    const response = await this.raw(url, method, body);
    if (!response) {
      return undefined;
    }
    const reply = JSON.parse(response) as DemoReply;
    if (typeof reply.frame_id !== 'string' || typeof reply.text !== 'string' || !reply.text.trim()) {
      throw new Error('后端回复缺少 frame_id 或 text');
    }
    const text = normalizeBroadcast(reply.text);
    // Audio must agree with the text we accepted. Never play rejected wording.
    return { frame_id: reply.frame_id, text: text,
      audio_base64: text === reply.text ? reply.audio_base64 : undefined };
  }

  private async raw(url: string, method: http.RequestMethod, body?: string,
    readTimeout: number = 180000): Promise<string | undefined> {
    const request = http.createHttp();
    this.pending = request;
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: { 'Content-Type': 'application/json' },
        connectTimeout: 3000,
        readTimeout: readTimeout,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      const response = await request.request(url, options);
      if (response.responseCode === 204) {
        return undefined;
      }
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        throw new Error(`后端返回 HTTP ${response.responseCode}`);
      }
      return response.result;
    } finally {
      if (this.pending === request) {
        this.cancel();
      }
    }
  }
}
