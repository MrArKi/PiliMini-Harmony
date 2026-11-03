/** 媒体时钟只读锚点，不读播放器、不调速/seek。调用者传systemDateTime ACTIVE毫秒。 */
export class DanmakuClock {
  private media: number = 0;
  private stamp: number = 0;
  private rate: number = 1;
  private running: boolean = false;
  private revision: number = -1;
  private initialized: boolean = false;
  private correction: number = 0;
  private sampleReady: boolean = false;
  private samplePosition: number = 0;
  private sampleStamp: number = 0;
  private advanceLow: number = 0;
  private advanceHigh: number = 0;
  private motionLow: number = 0;
  private motionHigh: number = 0;
  private estimated: boolean = false;

  /** 返回true表示离散跳变，调用者应清轨道并重新定位投放游标。 */
  update(positionMs: number, monotonicMs: number, speed: number, running: boolean, revision: number,
    smooth: boolean = true, observed: boolean = true): boolean {
    const position: number = Number.isFinite(positionMs) ? Math.max(0, positionMs) : this.media;
    const now: number = Number.isFinite(monotonicMs) ? monotonicMs : this.stamp;
    const rate: number = Number.isFinite(speed) ? Math.max(0.25, Math.min(5, speed)) : 1;
    // 切速先提交当前时刻的连续锚点，原生异步读取仍可能带回较早采样。
    // 同一媒体代际的迟到锚点不能回拨时钟、清轨；真实seek/换源的revision优先处理。
    if (this.initialized && revision === this.revision && now < this.stamp) { return false; }
    const predicted: number = this.position(now);
    const timelineChanged: boolean = !this.initialized || revision !== this.revision;
    if (timelineChanged) {
      this.sampleReady = false; this.advanceLow = 0; this.advanceHigh = 0;
      this.sampleStamp = now; this.motionLow = running ? rate : 0; this.motionHigh = this.motionLow;
      this.estimated = false;
    } else if (this.sampleReady) {
      // 真实采样间的推进不受显示外推1500ms上限影响；暂停段按0累计。
      const elapsed: number = Math.max(0, now - this.sampleStamp);
      this.advanceLow += elapsed * this.motionLow; this.advanceHigh += elapsed * this.motionHigh;
      this.sampleStamp = now;
    }
    // 合成控制只限定尚未确认的速率区间，不以外推位置检测真实跳变。
    const tolerance: number = 900 * Math.max(1, this.rate, rate);
    const discontinuity: boolean = timelineChanged || (observed && this.sampleReady &&
      (position < this.samplePosition + this.advanceLow - tolerance ||
        position > this.samplePosition + this.advanceHigh + tolerance));
    // 采样断档恢复直接采用真实锚点，不把断档前旧倍速的外推误差带入新时钟。
    const continuous: boolean = smooth && now - this.stamp <= 1500 && !discontinuity &&
      this.running && running && !(observed && this.estimated);
    // 连续播放保留采样边界的显示位置，只在随后1秒缓校；推进速度始终至少为正常值90%。
    this.media = continuous ? predicted : position;
    this.correction = continuous ? Math.max(-rate * 100, Math.min(rate * 100, position - predicted)) : 0;
    if (observed) {
      this.sampleReady = true; this.samplePosition = position; this.sampleStamp = now;
      this.advanceLow = 0; this.advanceHigh = 0;
      this.motionLow = running ? rate : 0; this.motionHigh = this.motionLow; this.estimated = false;
    } else {
      this.estimated = true;
      if (running && this.running) {
        this.motionLow = Math.min(this.motionLow, rate); this.motionHigh = Math.max(this.motionHigh, rate);
      } else { this.motionLow = running ? rate : 0; this.motionHigh = this.motionLow; }
    }
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
    this.sampleReady = false; this.samplePosition = 0; this.sampleStamp = 0;
    this.advanceLow = 0; this.advanceHigh = 0; this.motionLow = 0; this.motionHigh = 0; this.estimated = false;
  }
}
