import common from '@ohos.app.ability.common';
import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import http from '@ohos.net.http';
import { DemoReply } from './DemoApi';
import { LocalRuntime } from './LocalRuntime';
import { TEST_BROADCAST } from './BroadcastPolicy';
import { MAP_MAX_AGE_MS } from './MinimapTracker';
import { LocalNeuralSpeech } from './LocalNeuralSpeech';
import { DEFAULT_SPEECH_RATE } from './BattleBriefing';
import { assertCloudFrameFresh } from './CloudTiming';

export class VoicePlayer {
  lastPlaybackAgeMs?: number;
  private sequence: number = 0;
  private finish: (() => void) | undefined;
  private pending: http.HttpRequest | undefined;
  private sessionUsers: number = 0;

  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  cancel(): void {
    ++this.sequence;
    this.finish?.();
    this.pending?.destroy();
    this.pending = undefined;
  }

  async playSample(): Promise<void> {
    const sequence = ++this.sequence;
    const data = await this.context.resourceManager.getRawFileContent('demo_voice.wav');
    if (sequence !== this.sequence) return;
    await this.play({ frame_id: 'test-sample', text: TEST_BROADCAST,
      audio_base64: new util.Base64Helper().encodeToStringSync(data) });
  }

  async play(reply: DemoReply, ttsOrigin: string = '', localNeural: boolean = true,
    maxAgeMs: number = MAP_MAX_AGE_MS, speechRate: number = DEFAULT_SPEECH_RATE): Promise<void> {
    const sequence = ++this.sequence;
    this.lastPlaybackAgeMs = undefined;
    let player: media.AVPlayer | undefined;
    let session: audio.AudioSessionManager | undefined;
    let file: fs.File | undefined;
    let path = '';
    try {
      if (reply.captured_at !== undefined) assertCloudFrameFresh(reply.captured_at, maxAgeMs);
      let source: media.AVFileDescriptor;
      let buffer: ArrayBuffer;
      if (reply.audio_base64) {
        if (reply.audio_base64.length > 2 * 1024 * 1024) {
          throw new Error('语音数据过大');
        }
        const data = new util.Base64Helper().decodeSync(reply.audio_base64);
        buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      } else if (ttsOrigin) {
        buffer = await this.neuralSpeech(reply, ttsOrigin);
      } else if (localNeural) {
        buffer = await LocalNeuralSpeech.synthesize(this.context, reply.text, speechRate);
      } else {
        buffer = await new LocalRuntime(this.context).speech(reply.text);
      }
      if (sequence !== this.sequence) {
        return;
      }
      if (reply.captured_at !== undefined) assertCloudFrameFresh(reply.captured_at, maxAgeMs);
      path = `${this.context.cacheDir}/game-voice-${Date.now()}-${sequence}.wav`;
      file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      if (fs.writeSync(file.fd, buffer) !== buffer.byteLength) {
        throw new Error('语音缓存写入不完整');
      }
      source = { fd: file.fd, offset: 0, length: buffer.byteLength };
      session = audio.getAudioManager().getSessionManager();
      ++this.sessionUsers;
      await session.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS });
      if (sequence !== this.sequence) return;
      player = await media.createAVPlayer();
      if (sequence !== this.sequence) {
        return;
      }
      await this.playFile(player, source, sequence, Math.max(15000, Math.min(120000, reply.text.length * 500 + 5000)),
        reply.captured_at, maxAgeMs);
    } finally {
      try {
        await player?.release();
      } finally {
        if (session) {
          --this.sessionUsers;
          if (this.sessionUsers === 0) {
            try { await session.deactivateAudioSession(); } catch (_) {}
          }
        }
        if (file !== undefined) {
          fs.closeSync(file);
        }
        if (path) {
          fs.unlinkSync(path);
        }
      }
    }
  }

  private async neuralSpeech(reply: DemoReply, origin: string): Promise<ArrayBuffer> {
    if (!/^https?:\/\/[^/\s?#@]+$/.test(origin)) {
      throw new Error('请填写完整的 TTS 服务地址');
    }
    const request = http.createHttp();
    this.pending = request;
    try {
      const response = await request.request(`${origin}/tts`, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify({ frame_id: reply.frame_id, text: reply.text }),
        connectTimeout: 3000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        throw new Error(`TTS 返回 HTTP ${response.responseCode}，请确认服务已启用中文模型`);
      }
      const result = JSON.parse(response.result) as DemoReply;
      if (result.frame_id !== reply.frame_id || result.text !== reply.text ||
          !result.audio_base64 || result.audio_base64.length > 2 * 1024 * 1024) {
        throw new Error('TTS 音频与当前播报文本不匹配');
      }
      const bytes = new util.Base64Helper().decodeSync(result.audio_base64);
      return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    } finally {
      request.destroy();
      if (this.pending === request) this.pending = undefined;
    }
  }

  private playFile(player: media.AVPlayer, source: media.AVFileDescriptor, sequence: number, timeoutMs: number,
    capturedAt?: number, maxAgeMs: number = MAP_MAX_AGE_MS): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const settle = (error?: Error): void => {
        if (this.finish !== cancel) {
          return;
        }
        this.finish = undefined;
        clearTimeout(timer);
        if (error) {
          reject(error);
        } else {
          resolve();
        }
      };
      const cancel = (): void => settle();
      const timer = setTimeout(() => settle(new Error('音频播放超时')), timeoutMs);
      this.finish = cancel;
      player.on('error', (error) => settle(new Error(`播放失败 ${error.code}: ${error.message}`)));
      player.on('stateChange', (state) => {
        if (sequence !== this.sequence || this.finish !== cancel) {
          return;
        }
        if (state === 'initialized') {
          try {
            player.audioRendererInfo = {
              content: audio.ContentType.CONTENT_TYPE_SPEECH,
              usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT,
              rendererFlags: 0
            };
            player.prepare().catch((error: Error) => settle(error));
          } catch (error) {
            settle(error as Error);
          }
        } else if (state === 'prepared') {
          try {
            if (capturedAt !== undefined) {
              assertCloudFrameFresh(capturedAt, maxAgeMs);
              this.lastPlaybackAgeMs = Math.max(0, Date.now() - capturedAt);
            }
            player.play().catch((error: Error) => settle(error));
          } catch (error) { settle(error as Error); }
        } else if (state === 'paused') {
          settle(new Error('语音播放被其他应用暂停，请检查游戏音频或系统音频设置'));
        } else if (state === 'completed') {
          settle();
        }
      });
      try {
        player.fdSrc = source;
      } catch (error) {
        settle(error as Error);
      }
    });
  }
}
