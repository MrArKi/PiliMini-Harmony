import { DanmakuItem } from '../../model/danmaku';

/** 与position同次采样的ACTIVE毫秒必须由播放器提供，不用发布时刻冒充采样时刻。 */
export interface DanmakuPlaybackInput {
  cid: number;
  duration: number;
  position: number;
  speed: number;
  running: boolean;
  timeRevision: number;
  sampledAt: number;
  seeking: boolean;
}

function copyInput(value: DanmakuPlaybackInput): DanmakuPlaybackInput {
  return { cid: value.cid, duration: value.duration, position: value.position, speed: value.speed,
    running: value.running, timeRevision: value.timeRevision, sampledAt: value.sampledAt, seeking: value.seeking };
}

/** 普通对象单订阅桥；复用播放器快照，不订阅mpv、不建立轮询。 */
export class DanmakuPlaybackFeed {
  private listener: ((value: DanmakuPlaybackInput) => void) | undefined = undefined;
  private last: DanmakuPlaybackInput | undefined = undefined;

  publish(value: DanmakuPlaybackInput): void {
    if (!Number.isSafeInteger(value.cid) || value.cid < 0 || !Number.isFinite(value.duration) || value.duration < 0 ||
      !Number.isFinite(value.position) || value.position < 0 || !Number.isFinite(value.speed) || value.speed <= 0 ||
      !Number.isSafeInteger(value.timeRevision) || value.timeRevision < 0 || !Number.isFinite(value.sampledAt) || value.sampledAt < 0 ||
      typeof value.running !== 'boolean' || typeof value.seeking !== 'boolean') { return; }
    this.last = copyInput(value);
    if (this.listener !== undefined) { this.listener(copyInput(this.last)); }
  }

  attach(listener: (value: DanmakuPlaybackInput) => void): () => void {
    this.listener = listener;
    if (this.last !== undefined) { listener(copyInput(this.last)); }
    return (): void => { if (this.listener === listener) { this.listener = undefined; } };
  }

  /** cid的@Prop与普通对象发布先后均可重放同一份最新快照。 */
  peek(): DanmakuPlaybackInput | undefined { return this.last === undefined ? undefined : copyInput(this.last); }

  clear(): void { this.listener = undefined; this.last = undefined; }
}

export interface DanmakuLayerActions {
  hitTest: (x: number, y: number) => DanmakuItem | undefined;
  nearby: () => DanmakuItem[];
  hide: (key: string) => void;
  restoreHidden: () => void;
  retry: () => void;
  refreshRules: () => void;
}

/** UI与Canvas的单实例桥；Layer卸载即解绑，不保留Canvas、弹幕或网络实例。 */
export class DanmakuLayerHandle {
  private actions: DanmakuLayerActions | undefined = undefined;

  attach(actions: DanmakuLayerActions): () => void {
    this.actions = actions;
    return (): void => { if (this.actions === actions) { this.actions = undefined; } };
  }

  /** 坐标为实际视频Canvas局部vp；父层负责逆转contain缩放/居中偏移。 */
  hitTest(x: number, y: number): DanmakuItem | undefined {
    return this.actions === undefined ? undefined : this.actions.hitTest(x, y);
  }
  nearby(): DanmakuItem[] { return this.actions === undefined ? [] : this.actions.nearby(); }
  hide(key: string): void {
    if (this.actions === undefined) { throw new Error('弹幕暂不可用'); }
    this.actions.hide(key);
  }
  restoreHidden(): void { if (this.actions !== undefined) { this.actions.restoreHidden(); } }
  retry(): void { if (this.actions !== undefined) { this.actions.retry(); } }
  refreshRules(): void { if (this.actions !== undefined) { this.actions.refreshRules(); } }
}
