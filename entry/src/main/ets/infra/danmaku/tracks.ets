import { DanmakuItem, DanmakuOptions, ActiveDanmaku } from '../../model/danmaku';

/** 媒体毫秒排轨。自身无计时器/组件/网络，frame返回内部只读活动视图。 */
export class DanmakuTracks {
  private width: number = 0;
  private height: number = 0;
  private options: DanmakuOptions = new DanmakuOptions();
  private active: ActiveDanmaku[] = [];
  private admitted: Map<number, number> = new Map<number, number>();

  configure(width: number, height: number, options: DanmakuOptions): void {
    this.width = Number.isFinite(width) ? Math.max(0, width) : 0;
    this.height = Number.isFinite(height) ? Math.max(0, height) : 0;
    this.options = options;
    // 尺寸/字号变化后旧轨道不沿用。调用者从最新媒体时间恢复，不补发旧项。
    this.clear();
  }

  clear(): void { this.active.length = 0; this.admitted.clear(); }
  size(): number { return this.active.length; }

  /** 本机规则变化仅清命中活动项；保留同秒投放计数，不能靠反复切规则绕过密度上限。 */
  removeMatching(predicate: (item: DanmakuItem) => boolean): void {
    for (let index: number = this.active.length - 1; index >= 0; index--) {
      if (predicate(this.active[index].item)) { this.active.splice(index, 1); }
    }
  }

  frame(mediaMs: number): ActiveDanmaku[] {
    for (let i: number = this.active.length - 1; i >= 0; i--) {
      const item: ActiveDanmaku = this.active[i];
      if (mediaMs >= item.end || mediaMs < item.start) { this.active.splice(i, 1); continue; }
      item.x = item.item.mode === 1 ? this.width - (mediaMs - item.start) * item.velocity :
        (this.width - item.width) / 2;
    }
    return this.active;
  }

  private laneAvailable(lane: number, mode: number, left: number, width: number, velocity: number, now: number): boolean {
    const gap: number = Math.max(10, this.options.fontSize * 0.8);
    for (let i: number = 0; i < this.active.length; i++) {
      const old: ActiveDanmaku = this.active[i];
      if (old.lane !== lane || old.end <= now) { continue; }
      // 固定条目与滚动条目共享同一组行；不把静态弹幕叠在滚动轨道上。
      if (mode !== 1 || old.item.mode !== 1) { return false; }
      if (left <= old.x + old.width + gap) { return false; }
      if (velocity > old.velocity) {
        const catchAfter: number = (left - old.x - old.width - gap) / (velocity - old.velocity);
        const oldLeavesAfter: number = (old.x + old.width) / Math.max(0.0001, old.velocity);
        if (catchAfter < oldLeavesAfter) { return false; }
      }
    }
    return true;
  }

  /** restoring仅供重排原活动项或同暂停锚点恢复，不用于seek或历史补发。 */
  admit(item: DanmakuItem, mediaMs: number, measure: (text: string, fontSize: number) => number, restoring: boolean = false): boolean {
    const opts: DanmakuOptions = this.options;
    const duration: number = item.mode === 1 ? Math.max(3000, Math.min(14000, opts.scrollDuration)) :
      Math.max(2000, Math.min(8000, opts.fixedDuration));
    if (this.width <= 0 || this.height <= 0 || !Number.isFinite(mediaMs) ||
      mediaMs < item.time || (!restoring && mediaMs - item.time > 1000) || mediaMs >= item.time + duration ||
      (item.mode === 1 && !opts.scroll) || (item.mode === 4 && !opts.bottom) || (item.mode === 5 && !opts.top) ||
      (item.mode !== 1 && item.mode !== 4 && item.mode !== 5)) { return false; }
    this.frame(mediaMs);
    for (let i: number = 0; i < this.active.length; i++) {
      if (this.active[i].item.key === item.key) { return false; }
    }
    const max: number = Math.max(1, Math.min(60, Math.floor(opts.maxActive)));
    if (this.active.length >= max) { return false; }
    const second: number = Math.floor(item.time / 1000);
    const currentSecond: number = Math.floor(mediaMs / 1000);
    this.admitted.forEach((_count: number, bucket: number): void => {
      if (bucket < currentSecond - 2 || bucket > currentSecond) { this.admitted.delete(bucket); }
    });
    const admitted: number = this.admitted.get(second) || 0;
    if (admitted >= Math.max(1, Math.min(20, Math.floor(opts.perSecond)))) { return false; }
    const font: number = Math.max(10, Math.min(30, opts.fontSize));
    const textWidth: number = measure(item.text, font);
    if (!Number.isFinite(textWidth) || textWidth <= 0 || textWidth > this.width * 4) { return false; }
    const lineHeight: number = Math.ceil(font * Math.max(1, Math.min(2, opts.lineHeight)));
    const area: number = Math.max(0.25, Math.min(1, opts.area));
    const laneCount: number = Math.min(max, Math.floor((this.height * area - 4) / lineHeight));
    if (laneCount <= 0) { return false; }
    const velocity: number = item.mode === 1 ? (this.width + textWidth) / duration : 0;
    const left: number = item.mode === 1 ? this.width - (mediaMs - item.time) * velocity :
      (this.width - textWidth) / 2;
    for (let step: number = 0; step < laneCount; step++) {
      const lane: number = item.mode === 4 ? laneCount - step - 1 : step;
      if (!this.laneAvailable(lane, item.mode, left, textWidth, velocity, mediaMs)) { continue; }
      this.active.push({ item: item, start: item.time, end: item.time + duration, lane: lane,
        x: left, y: 3 + font + lane * lineHeight, width: textWidth, fontSize: font, velocity: velocity });
      this.admitted.set(second, admitted + 1); return true;
    }
    return false;
  }
}
