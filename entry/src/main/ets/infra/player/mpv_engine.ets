import type { NativePlayerEvent, NativePlayerSnapshot, NativePlayerStats } from 'libpilimini_player.so';
import type { NativePlayerApi } from './native_player_module';
import { UA_PC } from '../../config/constants';

/** 每个实例仅有一个mpv句柄，音画均由该句柄处理。 */
export class MpvEngine {
  private static nativeApi: NativePlayerApi | undefined = undefined;
  private static nativeLoading: Promise<NativePlayerApi> | undefined = undefined;
  private handle: number = 0;
  private closed: boolean = false;
  private pendingSnapshot: Promise<NativePlayerSnapshot> | undefined = undefined;
  private disposal: Promise<void> | undefined = undefined;
  private api: NativePlayerApi;

  private constructor(api: NativePlayerApi) { this.api = api; }

  private static async loadNative(): Promise<NativePlayerApi> {
    if (MpvEngine.nativeApi !== undefined) { return MpvEngine.nativeApi; }
    let loading: Promise<NativePlayerApi> | undefined = MpvEngine.nativeLoading;
    if (loading === undefined) {
      loading = import('./native_player_module').then((module): NativePlayerApi => {
        const api: NativePlayerApi = module.getNativePlayer();
        MpvEngine.nativeApi = api;
        return api;
      });
      MpvEngine.nativeLoading = loading;
    }
    try { return await loading; }
    finally {
      // 只清理本次请求，失败可重试；并发等待者不能覆盖后来的导入请求。
      if (MpvEngine.nativeLoading === loading) { MpvEngine.nativeLoading = undefined; }
    }
  }

  static async create(surface: string, hardware: boolean, listener: (event: NativePlayerEvent) => void): Promise<MpvEngine> {
    const api: NativePlayerApi = await MpvEngine.loadNative();
    const engine: MpvEngine = new MpvEngine(api);
    engine.handle = await api.create(surface, hardware, (event: NativePlayerEvent): void => {
      // 初始化阶段的原生idle事件不交给尚未取得实例所有权的页面。
      if (!engine.closed && engine.handle > 0) { listener(event); }
    });
    return engine;
  }

  load(video: string, audio: string, position: number, paused: boolean): void {
    this.api.load(this.handle, video, audio, UA_PC, Math.max(0, position), paused);
  }
  play(): void { this.set('pause', 'no'); }
  pause(): void { this.set('pause', 'yes'); }
  seek(ms: number): void { this.api.command(this.handle, ['seek', (ms / 1000).toString(), 'absolute+exact']); }
  speed(value: number): void {
    this.set('speed', value.toString());
    this.set('cache-secs', (16 * value).toFixed(3));
    this.set('demuxer-hysteresis-secs', (16 * value / 1.5).toFixed(3));
  }
  volume(value: number): void { this.set('volume', (value * 100).toString()); }
  video(enabled: boolean): void { this.set('vid', enabled ? 'auto' : 'no'); }
  resize(width: number, height: number): void { this.set('ohos-surface-size', width.toString() + 'x' + height.toString()); }
  snapshot(diagnostics: boolean = false): Promise<NativePlayerSnapshot> {
    if (this.closed || this.handle <= 0) { return Promise.reject(new Error('Player released')); }
    if (this.pendingSnapshot !== undefined) { return this.pendingSnapshot; }
    const pending: Promise<NativePlayerSnapshot> = this.api.snapshotAsync(this.handle, diagnostics).finally((): void => {
      if (this.pendingSnapshot === pending) { this.pendingSnapshot = undefined; }
    });
    this.pendingSnapshot = pending;
    return pending;
  }
  private set(key: string, value: string): void {
    if (!this.closed && this.handle > 0) { this.api.set(this.handle, key, value); }
  }
  dispose(): Promise<void> {
    if (this.disposal !== undefined) { return this.disposal; }
    this.closed = true;
    const handle: number = this.handle;
    this.handle = 0;
    const reading: Promise<void> = this.pendingSnapshot === undefined ? Promise.resolve() :
      this.pendingSnapshot.then((): void => {}, (): void => {});
    this.disposal = reading.then((): Promise<void> => handle > 0 ? this.api.dispose(handle) : Promise.resolve());
    return this.disposal;
  }
  static stats(): NativePlayerStats {
    return MpvEngine.nativeApi !== undefined ? MpvEngine.nativeApi.stats() : { instances: 0, eventThreads: 0 };
  }
}
