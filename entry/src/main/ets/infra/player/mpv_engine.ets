import playerNative, { NativePlayerEvent, NativePlayerSnapshot, NativePlayerStats } from 'libpilimini_player.so';
import { UA_PC } from '../../config/constants';

/** 每个实例仅有一个mpv句柄，音画均由该句柄处理。 */
export class MpvEngine {
  private handle: number = 0;
  private closed: boolean = false;

  private constructor() {}

  static async create(surface: string, hardware: boolean, listener: (event: NativePlayerEvent) => void): Promise<MpvEngine> {
    const engine: MpvEngine = new MpvEngine();
    engine.handle = await playerNative.create(surface, hardware, (event: NativePlayerEvent): void => {
      // 初始化阶段的原生idle事件不交给尚未取得实例所有权的页面。
      if (!engine.closed && engine.handle > 0) { listener(event); }
    });
    return engine;
  }

  load(video: string, audio: string, position: number, paused: boolean): void {
    playerNative.load(this.handle, video, audio, UA_PC, Math.max(0, position), paused);
  }
  play(): void { this.set('pause', 'no'); }
  pause(): void { this.set('pause', 'yes'); }
  seek(ms: number): void { playerNative.command(this.handle, ['seek', (ms / 1000).toString(), 'absolute+exact']); }
  speed(value: number): void {
    this.set('speed', value.toString());
    this.set('cache-secs', (16 * value).toFixed(3));
    this.set('demuxer-hysteresis-secs', (16 * value / 1.5).toFixed(3));
  }
  volume(value: number): void { this.set('volume', (value * 100).toString()); }
  video(enabled: boolean): void { this.set('vid', enabled ? 'auto' : 'no'); }
  resize(width: number, height: number): void { this.set('ohos-surface-size', width.toString() + 'x' + height.toString()); }
  snapshot(diagnostics: boolean = false): NativePlayerSnapshot { return playerNative.snapshot(this.handle, diagnostics); }
  private set(key: string, value: string): void {
    if (!this.closed && this.handle > 0) { playerNative.set(this.handle, key, value); }
  }
  dispose(): Promise<void> {
    if (this.closed) { return Promise.resolve(); }
    this.closed = true;
    const handle: number = this.handle;
    this.handle = 0;
    return handle > 0 ? playerNative.dispose(handle) : Promise.resolve();
  }
  static stats(): NativePlayerStats { return playerNative.stats(); }
}
