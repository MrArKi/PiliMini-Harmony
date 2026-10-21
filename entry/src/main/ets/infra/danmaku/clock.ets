/** 媒体时钟只读锚点，不读播放器、不调速/seek。调用者传systemDateTime ACTIVE毫秒。 */
export class DanmakuClock {
  private media: number = 0;
  private stamp: number = 0;
  private rate: number = 1;
  private running: boolean = false;
  private revision: number = -1;
  private initialized: boolean = false;
  private correction: number = 0;

  /** 返回true表示离散跳变，调用者应清轨道并重新定位投放游标。 */
  update(positionMs: number, monotonicMs: number, speed: number, running: boolean, revision: number): boolean {
    const position: number = Number.isFinite(positionMs) ? Math.max(0, positionMs) : this.media;
    const now: number = Number.isFinite(monotonicMs) ? monotonicMs : this.stamp;
    const rate: number = Number.isFinite(speed) ? Math.max(0.25, Math.min(5, speed)) : 1;
    const predicted: number = this.position(now);
    const discontinuity: boolean = !this.initialized || revision !== this.revision ||
      Math.abs(position - predicted) > 900 || now < this.stamp || now - this.stamp > 1500;
    const continuous: boolean = !discontinuity && this.running && running && rate === this.rate;
    // 连续播放保留采样边界的显示位置，只在随后1秒缓校；推进速度始终至少为正常值90%。
    this.media = continuous ? predicted : position;
    this.correction = continuous ? Math.max(-rate * 100, Math.min(rate * 100, position - predicted)) : 0;
    this.stamp = now;
    this.rate = rate;
    this.running = running; this.revision = revision; this.initialized = true;
    return discontinuity;
  }

  position(monotonicMs: number): number {
    if (!this.running || !this.initialized || !Number.isFinite(monotonicMs)) { return this.media; }
    // 快照长时断流不允许无限外推；已有500ms快照正常时不触达此上限。
    const elapsed: number = Math.max(0, Math.min(1500, monotonicMs - this.stamp));
    return this.media + elapsed * this.rate + this.correction * Math.min(1, elapsed / 1000);
  }

  reset(): void {
    this.initialized = false; this.running = false; this.media = 0; this.stamp = 0;
    this.revision = -1; this.correction = 0;
  }
}
