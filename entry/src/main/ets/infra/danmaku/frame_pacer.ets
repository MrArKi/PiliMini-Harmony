/** DisplaySync负责max/expected60；这里只去除同一VSYNC重复回调，不二次按固定周期筛帧。 */
export class DanmakuFramePacer {
  private last: number = -1;

  reset(): void { this.last = -1; }

  due(timestampNs: number): boolean {
    if (!Number.isFinite(timestampNs) || timestampNs < 0) { return true; }
    if (timestampNs === this.last) { return false; }
    this.last = timestampNs;
    return true;
  }
}
