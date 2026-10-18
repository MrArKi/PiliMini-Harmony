/** Nara底部导航：单击回顶/顶端刷新，500ms内再次点击直接刷新。 */
export class FeedNavRequest {
  serial: number;
  refreshOnly: boolean;

  constructor(serial: number = 0, refreshOnly: boolean = false) {
    this.serial = serial;
    this.refreshOnly = refreshOnly;
  }
}

/** 每个分类独立持有；无定时器、全局订阅或图片引用。 */
export class FeedNavigation {
  scroller: Scroller = new Scroller();
  viewportHeight: number = 0;
  private returningToTop: boolean = false;
  private lastRefreshAt: number = 0;

  shouldRefresh(request: FeedNavRequest, canScroll: boolean): boolean {
    if (request.serial <= 0) { return false; }
    if (!request.refreshOnly) {
      if (this.returningToTop) { return false; }
      if (canScroll && Math.abs(this.scroller.currentOffset().yOffset) > 0.5) {
        this.toTop();
        return false;
      }
    }
    const now: number = Date.now();
    if (now - this.lastRefreshAt < 500) { return false; }
    this.lastRefreshAt = now;
    return true;
  }

  toTop(): void {
    const offset: number = this.scroller.currentOffset().yOffset;
    if (Math.abs(offset) <= 0.5) { return; }
    // Nara animTo：长列表最多滚两屏，避免回顶穿过大量图片。
    const limit: number = this.viewportHeight * 2;
    if (limit > 0 && offset > limit) {
      this.scroller.scrollTo({ xOffset: 0, yOffset: limit });
    }
    this.returningToTop = true;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0,
      animation: { duration: 500, curve: Curve.EaseInOut } });
  }

  onScrollStop(): void { this.returningToTop = false; }
}
