import { BinaryRequest } from '../http/binary_http';
import { wbiSign, getMixinKeyCached } from '../sign/wbi';
import { buildQuery } from '../http/http';
import { API_BASE } from '../../config/constants';
import { AppError } from '../error/app_error';
import { DanmakuItem, DanmakuSegment, DanmakuStreamStats, DanmakuStreamState, DANMAKU_SEGMENT_MS,
  DANMAKU_PREFETCH_MS, DANMAKU_RESPONSE_MAX } from '../../model/danmaku';
import { parseDanmakuSegment } from './protobuf';

interface SegmentFailure { index: number; message: string; }
interface PendingSegment { index: number; generation: number; request: BinaryRequest; }

// 冷WBI密钥共用一个在途请求，快速换源不能创建大量不可取消nav任务。
let pendingMixin: Promise<string> | undefined = undefined;
function prepareMixin(): Promise<string> {
  if (pendingMixin === undefined) {
    pendingMixin = getMixinKeyCached().finally((): void => { pendingMixin = undefined; });
  }
  return pendingMixin;
}

function lowerBound(items: DanmakuItem[], time: number): number {
  let low: number = 0, high: number = items.length;
  while (low < high) {
    const mid: number = Math.floor((low + high) / 2);
    if (items[mid].time <= time) { low = mid + 1; } else { high = mid; }
  }
  return low;
}

/** 单播放器实例的6分钟段窗口。失败段只在明确retryCurrent/新source后重试，无定时器。 */
export class DanmakuStream {
  private cid: number = 0;
  private duration: number = 0;
  private position: number = 0;
  private enabled: boolean = false;
  private disposed: boolean = false;
  private generation: number = 0;
  private segments: Map<number, DanmakuSegment> = new Map<number, DanmakuSegment>();
  private pending: PendingSegment[] = [];
  private failures: SegmentFailure[] = [];
  private onChanged: () => void;
  private onError: (message: string) => void;
  constructor(onChanged: () => void, onError: (message: string) => void) {
    this.onChanged = onChanged; this.onError = onError;
  }

  setSource(cid: number, durationMs: number): void {
    const usedCid: number = Number.isSafeInteger(cid) && cid > 0 ? cid : 0;
    const usedDuration: number = Number.isFinite(durationMs) ? Math.max(0, durationMs) : 0;
    if (this.cid === usedCid) { this.duration = usedDuration; return; }
    this.cancelAll(); this.cid = usedCid; this.duration = usedDuration; this.position = 0;
    this.segments.clear(); this.failures.length = 0;
    // 等真实position快照update后才取段，避免续播先下载第1段。
  }

  setEnabled(enabled: boolean): void {
    if (this.disposed || enabled === this.enabled) { return; }
    this.enabled = enabled;
    if (!enabled) { this.cancelAll(); this.segments.clear(); this.failures.length = 0; }
  }

  /** 同cid seek/画质重开时取消在途工作但保留原始近邻缓存；调用者暂停update直到新锚点。 */
  cancelPending(): void { this.cancelAll(); }

  private currentIndex(): number { return Math.floor(this.position / DANMAKU_SEGMENT_MS) + 1; }
  private validIndex(index: number): boolean {
    return index > 0 && (this.duration <= 0 || (index - 1) * DANMAKU_SEGMENT_MS < this.duration);
  }
  private failed(index: number): boolean {
    for (let i: number = 0; i < this.failures.length; i++) { if (this.failures[i].index === index) { return true; } }
    return false;
  }
  private requesting(index: number): boolean {
    for (let i: number = 0; i < this.pending.length; i++) { if (this.pending[i].index === index) { return true; } }
    return false;
  }
  private cancelAll(): void {
    this.generation++;
    for (let i: number = 0; i < this.pending.length; i++) { this.pending[i].request.cancel(); }
    this.pending.length = 0;
  }
  private trim(): void {
    const center: number = this.currentIndex();
    this.segments.forEach((_segment: DanmakuSegment, index: number): void => {
      if (Math.abs(index - center) > 1) { this.segments.delete(index); }
    });
    for (let i: number = this.failures.length - 1; i >= 0; i--) {
      if (Math.abs(this.failures[i].index - center) > 1) { this.failures.splice(i, 1); }
    }
    // 正常跨段保留近邻请求；远seek取消旧请求，释放并发槽优先目标段。
    for (let i: number = this.pending.length - 1; i >= 0; i--) {
      if (Math.abs(this.pending[i].index - center) > 1) {
        this.pending[i].request.cancel(); this.pending.splice(i, 1);
      }
    }
  }

  update(positionMs: number, allowPrefetch: boolean): void {
    if (this.disposed || !Number.isFinite(positionMs)) { return; }
    this.position = Math.max(0, this.duration > 0 ? Math.min(positionMs, Math.max(0, this.duration - 1)) : positionMs);
    this.trim();
    if (!this.enabled || this.cid <= 0) { return; }
    const center: number = this.currentIndex();
    this.schedule(center);
    if (allowPrefetch && center * DANMAKU_SEGMENT_MS - this.position <= DANMAKU_PREFETCH_MS) { this.schedule(center + 1); }
  }

  /** 返回(from,to]；最多2秒窗口，支持3x下500ms快照的向前待投放缓冲。 */
  collect(fromMs: number, toMs: number): DanmakuItem[] {
    const output: DanmakuItem[] = [];
    if (!this.enabled || !Number.isFinite(fromMs) || !Number.isFinite(toMs) || toMs < fromMs) { return output; }
    const from: number = Math.max(fromMs, toMs - 2000);
    const first: number = Math.max(1, Math.floor(Math.max(0, from) / DANMAKU_SEGMENT_MS) + 1);
    const last: number = Math.floor(Math.max(0, toMs) / DANMAKU_SEGMENT_MS) + 1;
    for (let index: number = first; index <= last; index++) {
      const segment: DanmakuSegment | undefined = this.segments.get(index);
      if (segment === undefined || segment.closed) { continue; }
      const items: DanmakuItem[] = segment.items;
      for (let i: number = lowerBound(items, from); i < items.length && items[i].time <= toMs; i++) { output.push(items[i]); }
    }
    return output;
  }

  /** 当前时间附近的已加载原始池；不发请求、不全片扫描，供选择列表使用。 */
  nearby(positionMs: number, radiusMs: number = 15000, limit: number = 120): DanmakuItem[] {
    const output: DanmakuItem[] = [];
    if (!this.enabled || !Number.isFinite(positionMs)) { return output; }
    const radius: number = Number.isFinite(radiusMs) ? Math.max(0, Math.min(60000, radiusMs)) : 15000;
    const maximum: number = Number.isFinite(limit) ? Math.max(1, Math.min(200, Math.floor(limit))) : 120;
    this.segments.forEach((segment: DanmakuSegment): void => {
      if (segment.closed) { return; }
      const items: DanmakuItem[] = segment.items;
      for (let i: number = lowerBound(items, positionMs - radius - 1);
        i < items.length && items[i].time <= positionMs + radius; i++) { output.push(items[i]); }
    });
    if (output.length > maximum) {
      output.sort((a: DanmakuItem, b: DanmakuItem): number => Math.abs(a.time - positionMs) - Math.abs(b.time - positionMs));
      output.length = maximum;
    }
    output.sort((a: DanmakuItem, b: DanmakuItem): number => a.time - b.time || a.key.localeCompare(b.key));
    return output;
  }

  currentState(): DanmakuStreamState {
    if (this.disposed || !this.enabled || this.cid <= 0) { return 'idle'; }
    const index: number = this.currentIndex();
    const segment: DanmakuSegment | undefined = this.segments.get(index);
    if (segment !== undefined) { return segment.closed ? 'closed' : (segment.items.length > 0 ? 'ready' : 'empty'); }
    if (this.failed(index)) { return 'error'; }
    return this.requesting(index) ? 'loading' : 'idle';
  }

  retryCurrent(): void {
    const index: number = this.currentIndex();
    for (let i: number = this.failures.length - 1; i >= 0; i--) {
      if (this.failures[i].index === index) { this.failures.splice(i, 1); }
    }
    if (!this.disposed && this.enabled) { this.schedule(index); }
  }

  private schedule(index: number): void {
    if (this.disposed || !this.enabled || this.pending.length >= 2 || !this.validIndex(index) ||
      this.segments.has(index) || this.failed(index) || this.requesting(index)) { return; }
    const request: BinaryRequest = new BinaryRequest();
    const entry: PendingSegment = { index: index, generation: this.generation, request: request };
    this.pending.push(entry); this.load(entry, this.cid);
  }

  private active(entry: PendingSegment): boolean {
    return !this.disposed && this.enabled && entry.generation === this.generation &&
      this.pending.indexOf(entry) >= 0 && Math.abs(entry.index - this.currentIndex()) <= 1;
  }

  private async load(entry: PendingSegment, cid: number): Promise<void> {
    let completed: boolean = false;
    let failureCode: number | undefined = undefined;
    try {
      await prepareMixin();
      if (!this.active(entry)) { return; }
      const unsigned: Record<string, string> = {};
      unsigned['type'] = '1'; unsigned['oid'] = cid.toString(); unsigned['segment_index'] = entry.index.toString();
      const params: Record<string, string> = await wbiSign(unsigned);
      if (!this.active(entry)) { return; }
      const bytes: ArrayBuffer = await entry.request.get(API_BASE + '/x/v2/dm/wbi/web/seg.so?' + buildQuery(params), DANMAKU_RESPONSE_MAX);
      if (!this.active(entry)) { return; }
      const segment: DanmakuSegment = await parseDanmakuSegment(bytes, entry.index, (): boolean => !this.active(entry));
      if (!this.active(entry)) { return; }
      this.segments.set(entry.index, segment); this.trim();
      this.onChanged();
      completed = true;
    } catch (error) {
      if (!this.active(entry)) { return; }
      failureCode = error instanceof AppError ? error.code : 0;
      const message: string = error instanceof AppError && error.code === -101 ? '登录已失效' : '弹幕加载失败，可在设置中重试';
      this.failures.push({ index: entry.index, message: message }); this.trim();
      if (entry.index === this.currentIndex()) { this.onError(message); }
    } finally {
      const position: number = this.pending.indexOf(entry);
      if (position >= 0) { this.pending.splice(position, 1); }
      // 只在单次加载结束输出匿名预算；先移除完成项，requests是真实剩余在途数。
      if (completed) {
        const stats: DanmakuStreamStats = this.stats();
        console.info('[PiliMini-dm] segment index=' + entry.index.toString() +
          ' segments=' + stats.segments.toString() + ' items=' + stats.items.toString() +
          ' payload=' + stats.payloadBytes.toString() + ' requests=' + stats.activeRequests.toString());
      } else if (failureCode !== undefined) {
        console.warn('[PiliMini-dm] segment-failed index=' + entry.index.toString() + ' code=' + failureCode.toString());
      }
      // 不在finally自动排下一轮：失败不会在500ms快照下形成请求循环。
    }
  }

  stats(): DanmakuStreamStats {
    let items: number = 0, payload: number = 0, sampled: number = 0;
    this.segments.forEach((segment: DanmakuSegment): void => {
      items += segment.items.length; payload += segment.payloadBytes; if (segment.sampled) { sampled++; }
    });
    return { segments: this.segments.size, items: items, payloadBytes: payload, activeRequests: this.pending.length,
      failedSegments: this.failures.length, sampledSegments: sampled };
  }

  dispose(): void {
    if (this.disposed) { return; }
    this.disposed = true; this.cancelAll(); this.segments.clear(); this.failures.length = 0;
    this.onChanged = (): void => {}; this.onError = (_message: string): void => {};
  }
}
