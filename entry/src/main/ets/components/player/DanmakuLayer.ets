import displaySync from '@ohos.graphics.displaySync';
import systemDateTime from '@ohos.systemDateTime';
import { DanmakuItem, DanmakuOptions, ActiveDanmaku, DanmakuStreamState } from '../../model/danmaku';
import { DanmakuClock } from '../../infra/danmaku/clock';
import { DanmakuFramePacer } from '../../infra/danmaku/frame_pacer';
import { DanmakuTracks } from '../../infra/danmaku/tracks';
import { DanmakuStream } from '../../infra/danmaku/stream';
import { DanmakuPreferences, danmakuOptions } from '../../infra/danmaku/settings';
import { DanmakuRule, DanmakuRuleStore, DanmakuRuleMatcher } from '../../infra/danmaku/rules';
import { DanmakuPlaybackFeed, DanmakuPlaybackInput, DanmakuLayerHandle } from '../../infra/danmaku/playback_feed';
import { onAppBackground, onAppForeground } from '../../infra/event/app_events';

interface MeasuredDanmaku { width: number; left: number; right: number; ascent: number; descent: number; }
interface PaintedDanmaku { item: DanmakuItem; left: number; right: number; top: number; bottom: number; color: string; }
interface FrozenDanmaku { cid: number; revision: number; position: number; items: DanmakuItem[]; }
interface DanmakuGlyph {
  item: DanmakuItem; measured: MeasuredDanmaku; color: string;
  bitmap: ImageBitmap | undefined; left: number; top: number; width: number; height: number;
  bytes: number; frame: number;
}

const MAX_PENDING: number = 240;
const MAX_RECENT: number = 256;
const MAX_HIDDEN: number = 512;
const MAX_MEASURED: number = 256;
const MAX_GLYPH_BYTES: number = 4 * 1024 * 1024;
const MAX_SINGLE_GLYPH_BYTES: number = 512 * 1024;

function copyItem(item: DanmakuItem): DanmakuItem {
  return { key: item.key, dmid: item.dmid, midHash: item.midHash, time: item.time, mode: item.mode,
    fontSize: item.fontSize, color: item.color, text: item.text, weight: item.weight };
}

/** 单Canvas共享实际Surface矩形与contain变换；不注册手势，不逐条创建ArkUI组件。 */
@Component
export struct DanmakuLayer {
  @Prop @Watch('onSourceChanged') cid: number = 0;
  @Prop @Watch('onVisibilityChanged') visible: boolean = true;
  @Prop @Watch('onStyleChanged') fullscreen: boolean = false;
  @Prop @Watch('onStyleChanged') preferences: DanmakuPreferences = new DanmakuPreferences();
  @StorageProp('imagePreviewVisible') @Watch('onVisibilityChanged') previewVisible: boolean = false;
  feed: DanmakuPlaybackFeed = new DanmakuPlaybackFeed();
  handle: DanmakuLayerHandle = new DanmakuLayerHandle();
  onStatus: (message: string) => void = () => {};

  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private clock: DanmakuClock = new DanmakuClock();
  private pacer: DanmakuFramePacer = new DanmakuFramePacer();
  private tracks: DanmakuTracks = new DanmakuTracks();
  private stream: DanmakuStream | undefined = undefined;
  private sync: displaySync.DisplaySync | undefined = undefined;
  private snapshot: DanmakuPlaybackInput | undefined = undefined;
  private options: DanmakuOptions = new DanmakuOptions();
  private drawFont: string = '600 15vp sans-serif';
  private ready: boolean = false;
  private destroyed: boolean = false;
  private isBackground: boolean = false;
  private awaitingSnapshot: boolean = false;
  private frozenResumeAllowed: boolean = false;
  private frozenActive: FrozenDanmaku | undefined = undefined;
  private wasEnabled: boolean = true;
  private sourceCid: number = 0;
  private canvasW: number = 0;
  private canvasH: number = 0;
  private lastSampledAt: number = 0;
  private lastFrameMedia: number = 0;
  private pending: DanmakuItem[] = [];
  private pendingIndex: number = 0;
  private recent: Set<string> = new Set<string>();
  private recentOrder: string[] = [];
  private hidden: Set<string> = new Set<string>();
  private measured: Map<string, MeasuredDanmaku> = new Map<string, MeasuredDanmaku>();
  private painted: PaintedDanmaku[] = [];
  private glyphs: Map<string, DanmakuGlyph> = new Map<string, DanmakuGlyph>();
  private glyphBytes: number = 0;
  private paintRevision: number = 0;
  private rules: DanmakuRule[] = [];
  private ruleMatcher: DanmakuRuleMatcher = new DanmakuRuleMatcher([]);
  private rulesReady: boolean = false;
  private rulesGeneration: number = 0;
  private status: string = '';
  private frames: number = 0;
  private starts: number = 0;
  private stops: number = 0;
  private stopBackground: (() => void) | undefined = undefined;
  private stopForeground: (() => void) | undefined = undefined;
  private stopFeed: (() => void) | undefined = undefined;
  private stopHandle: (() => void) | undefined = undefined;
  private readonly frameListener = (frame: displaySync.IntervalInfo): void => { this.onFrame(frame.timestamp); };
  private readonly pruneGlyph = (glyph: DanmakuGlyph, key: string): void => {
    if (glyph.frame !== this.paintRevision) { this.closeGlyph(glyph); this.glyphs.delete(key); }
  };

  aboutToAppear(): void {
    this.destroyed = false;
    this.sourceCid = this.cid;
    this.updateOptions();
    this.wasEnabled = this.effectiveEnabled();
    this.stream = new DanmakuStream((): void => { this.onDataChanged(); }, (message: string): void => { this.setStatus(message); });
    this.stopBackground = onAppBackground((): void => {
      this.isBackground = true;
      this.suspend('background');
    });
    this.stopForeground = onAppForeground((): void => {
      this.isBackground = false;
      this.awaitingSnapshot = true;
      // 下一次真实采样再恢复，不使用后台之前的旧锚点。
      this.resumeLatest();
    });
    this.stopHandle = this.handle.attach({
      hitTest: (x: number, y: number): DanmakuItem | undefined => this.hitTest(x, y),
      nearby: (): DanmakuItem[] => this.nearby(),
      hide: (key: string): void => this.hide(key),
      restoreHidden: (): void => this.restoreHidden(),
      retry: (): void => this.retry(),
      refreshRules: (): void => this.refreshRules()
    });
    this.stopFeed = this.feed.attach((value: DanmakuPlaybackInput): void => { this.receive(value); });
    this.refreshRules();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.rulesGeneration++;
    this.stopFrames('dispose');
    if (this.stopBackground !== undefined) { this.stopBackground(); this.stopBackground = undefined; }
    if (this.stopForeground !== undefined) { this.stopForeground(); this.stopForeground = undefined; }
    if (this.stopFeed !== undefined) { this.stopFeed(); this.stopFeed = undefined; }
    if (this.stopHandle !== undefined) { this.stopHandle(); this.stopHandle = undefined; }
    if (this.stream !== undefined) { this.stream.dispose(); }
    this.clearPicture();
    this.clock.reset();
    this.snapshot = undefined;
    this.frozenActive = undefined;
    this.hidden.clear(); this.measured.clear(); this.rules.length = 0;
    const requests: number = this.stream === undefined ? 0 : this.stream.stats().activeRequests;
    console.info('[PiliMini-dm] disposed frames=' + this.frames.toString() + ' active=' + this.tracks.size().toString() +
      ' requests=' + requests.toString() + ' starts=' + this.starts.toString() + ' stops=' + this.stops.toString());
    this.stream = undefined;
  }

  private now(): number { return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE); }
  private updateOptions(): void {
    this.options = danmakuOptions(this.preferences, this.fullscreen);
    const size: number = Math.max(10, Math.min(30, this.options.fontSize));
    this.drawFont = '600 ' + size.toString() + 'vp sans-serif';
  }
  private effectiveEnabled(): boolean {
    return this.preferences.enabled === true && (this.options.scroll || this.options.top || this.options.bottom);
  }
  private allowed(): boolean {
    return !this.destroyed && this.ready && this.rulesReady && this.visible && !this.previewVisible && !this.isBackground &&
      this.effectiveEnabled() && this.cid > 0 && this.canvasW > 0 && this.canvasH > 0;
  }
  private moving(): boolean {
    return this.allowed() && !this.awaitingSnapshot && this.snapshot !== undefined && this.snapshot.running && !this.snapshot.seeking;
  }
  private media(): number {
    const position: number = this.clock.position(this.now());
    return this.snapshot !== undefined && this.snapshot.duration > 0 ? Math.min(position, this.snapshot.duration) : position;
  }
  private setStatus(value: string): void {
    if (!this.destroyed && value !== this.status) { this.status = value; this.onStatus(value); }
  }
  private updateStatus(): void {
    if (!this.effectiveEnabled()) { this.setStatus(''); return; }
    if (!this.rulesReady || this.stream === undefined) { return; }
    const state: DanmakuStreamState = this.stream.currentState();
    switch (state) {
      case 'loading': this.setStatus('弹幕加载中…'); break;
      case 'error': this.setStatus('弹幕加载失败，可在设置中重试'); break;
      case 'closed': this.setStatus('此视频已关闭弹幕'); break;
      case 'empty': this.setStatus('暂无弹幕'); break;
      default: this.setStatus(''); break;
    }
  }

  private onSourceChanged(): void {
    if (this.sourceCid === this.cid) { return; }
    this.sourceCid = this.cid;
    this.frozenActive = undefined; this.frozenResumeAllowed = false;
    this.suspend('source');
    this.clock.reset(); this.snapshot = undefined; this.frozenResumeAllowed = false; this.hidden.clear(); this.measured.clear();
    if (this.stream !== undefined) { this.stream.setSource(this.cid, 0); }
    this.setStatus('');
    const latest: DanmakuPlaybackInput | undefined = this.feed.peek();
    if (latest !== undefined && latest.cid === this.cid) { this.receive(latest); }
  }
  private onVisibilityChanged(): void {
    if (!this.visible || this.previewVisible || this.isBackground) {
      this.suspend(this.previewVisible ? 'image-preview' : (this.isBackground ? 'background' : 'invisible'));
      return;
    }
    this.awaitingSnapshot = true;
    this.resumeLatest();
  }
  private onStyleChanged(): void {
    if (this.destroyed) { return; }
    const media: number = this.media();
    const active: DanmakuItem[] = this.activeForReconfigure(media);
    this.updateOptions();
    const enabled: boolean = this.effectiveEnabled();
    const becameEnabled: boolean = enabled && !this.wasEnabled;
    this.wasEnabled = enabled;
    if (!enabled) { this.suspend('disabled'); this.setStatus(''); return; }
    if (becameEnabled) {
      this.tracks.configure(this.canvasW, this.canvasH, this.options); this.clearPicture(); this.measured.clear();
      this.awaitingSnapshot = true; this.resumeLatest(); return;
    }
    this.reconfigure(active, media, 'style');
  }
  private activeForReconfigure(media: number): DanmakuItem[] {
    if (!this.allowed() || this.awaitingSnapshot || this.snapshot === undefined || this.snapshot.seeking) { return []; }
    const active: ActiveDanmaku[] = this.tracks.frame(media);
    const items: DanmakuItem[] = [];
    for (let index: number = 0; index < active.length; index++) { items.push(active[index].item); }
    return items;
  }
  /** 仅重排变化前仍活跃的原项，保留key去重窗与媒体时间，不从过去分段补发。 */
  private reconfigure(active: DanmakuItem[], media: number, reason: string): void {
    this.stopFrames(reason);
    this.tracks.configure(this.canvasW, this.canvasH, this.options);
    this.pending.length = 0; this.pendingIndex = 0; this.painted.length = 0; this.measured.clear(); this.clearGlyphs();
    if (this.ready) { this.context.clearRect(0, 0, this.canvasW, this.canvasH); }
    if (this.allowed() && !this.awaitingSnapshot) {
      for (let index: number = 0; index < active.length; index++) {
        const item: DanmakuItem = active[index];
        if (!this.excluded(item)) {
          this.tracks.admit(item, media, (text: string, size: number): number => this.measure(text, size).width, true);
        }
      }
      this.draw(media);
      this.refillPending(); this.startFrames();
    } else { this.resumeLatest(); }
  }

  private receive(value: DanmakuPlaybackInput): void {
    if (this.destroyed) { return; }
    if (value.cid !== this.cid) { this.frozenActive = undefined; return; }
    if (this.sourceCid !== value.cid) { this.onSourceChanged(); }
    if (value.running || value.seeking) { this.frozenResumeAllowed = false; }
    if (this.frozenActive !== undefined && !this.matchesFrozen(value)) { this.frozenActive = undefined; }
    this.snapshot = value;
    this.lastSampledAt = value.sampledAt;
    if (this.stream === undefined) { return; }
    this.stream.setSource(value.cid, value.duration);
    if (!this.visible || this.previewVisible || this.isBackground) {
      this.suspend('hidden-snapshot');
      return;
    }
    const now: number = this.now();
    const frozen: boolean = !value.running && !value.seeking;
    this.frozenResumeAllowed = frozen;
    if ((!frozen && now - value.sampledAt > 1500) || value.sampledAt > now + 1) { this.suspend('stale-snapshot'); return; }
    const wasWaiting: boolean = this.awaitingSnapshot;
    this.awaitingSnapshot = false;
    const jump: boolean = this.clock.update(value.position, value.sampledAt, value.speed,
      value.running && !value.seeking && this.allowed(), value.timeRevision);
    if (jump || wasWaiting || value.seeking) { this.clearPicture(); this.lastFrameMedia = value.position; }
    if (value.seeking) {
      this.awaitingSnapshot = true;
      this.stream.cancelPending();
      this.stopFrames('seeking');
      return;
    }
    this.stream.setEnabled(this.allowed());
    if (!this.allowed()) { this.stopFrames('unavailable'); return; }
    this.restoreFrozen(value);
    this.stream.update(value.position, value.running);
    this.updateStatus();
    if (value.running) { this.refillPending(); this.startFrames(); }
    else {
      this.stopFrames('paused'); this.pending.length = 0; this.pendingIndex = 0;
      this.draw(value.position); // 只由真实快照触发静帧，稳定暂停没有帧驱动。
    }
  }
  private resumeLatest(): void {
    const latest: DanmakuPlaybackInput | undefined = this.feed.peek();
    if (latest !== undefined && latest.cid === this.cid) { this.snapshot = latest; }
    if (this.snapshot === undefined) { return; }
    const frozen: boolean = !this.snapshot.running && !this.snapshot.seeking;
    // 暂停无需持续快照，旧采样仍是准确冻结位置；running恢复必须等新锚点。
    if (!this.awaitingSnapshot || (frozen && this.frozenResumeAllowed && this.visible && !this.previewVisible && !this.isBackground)) {
      this.receive(this.snapshot);
    }
  }
  private suspend(reason: string): void {
    if (reason === 'disabled' || reason === 'image-preview' || reason === 'background' ||
      reason === 'invisible' || reason === 'hidden-snapshot') { this.captureFrozen(); }
    else { this.frozenActive = undefined; }
    this.awaitingSnapshot = true;
    if (this.stream !== undefined) { this.stream.setEnabled(false); }
    this.clearPicture();
    this.stopFrames(reason);
  }
  private matchesFrozen(value: DanmakuPlaybackInput): boolean {
    const frozen: FrozenDanmaku | undefined = this.frozenActive;
    return frozen !== undefined && !value.running && !value.seeking && value.cid === frozen.cid &&
      value.timeRevision === frozen.revision && value.position === frozen.position;
  }
  /** Watch已是新的可见/开关值；只凭先前稳定暂停锚点保留原活动项，不依赖allowed。 */
  private captureFrozen(): void {
    const value: DanmakuPlaybackInput | undefined = this.snapshot;
    if (value === undefined || value.running || value.seeking || !this.frozenResumeAllowed ||
      value.cid !== this.cid || this.sourceCid !== this.cid) { this.frozenActive = undefined; return; }
    if (this.matchesFrozen(value)) { return; } // 重复隐藏采样不能用空轨道覆盖冻结项。
    if (this.awaitingSnapshot) { return; }
    const active: ActiveDanmaku[] = this.tracks.frame(value.position);
    if (active.length === 0) { return; }
    const items: DanmakuItem[] = [];
    for (let index: number = 0; index < Math.min(60, active.length); index++) { items.push(copyItem(active[index].item)); }
    this.frozenActive = { cid: value.cid, revision: value.timeRevision, position: value.position, items: items };
  }
  /** 仅在同一暂停锚点恢复这批原项；seek/播放/换源均作废，不从历史分段补发。 */
  private restoreFrozen(value: DanmakuPlaybackInput): void {
    const frozen: FrozenDanmaku | undefined = this.frozenActive;
    if (frozen === undefined || !this.matchesFrozen(value)) { return; }
    this.frozenActive = undefined;
    this.tracks.configure(this.canvasW, this.canvasH, this.options);
    this.measured.clear();
    for (let index: number = 0; index < frozen.items.length; index++) {
      const item: DanmakuItem = frozen.items[index];
      if (!this.excluded(item)) {
        this.tracks.admit(item, value.position, (text: string, size: number): number => this.measure(text, size).width, true);
        this.recent.add(item.key); this.recentOrder.push(item.key);
      }
    }
  }
  private clearPicture(): void {
    this.tracks.clear(); this.pending.length = 0; this.pendingIndex = 0;
    this.recent.clear(); this.recentOrder.length = 0; this.painted.length = 0;
    if (this.ready) { this.context.clearRect(0, 0, this.canvasW, this.canvasH); }
    this.clearGlyphs();
  }
  private onDataChanged(): void {
    if (!this.allowed() || this.stream === undefined) { return; }
    this.updateStatus();
    if (this.moving()) { this.refillPending(); this.startFrames(); }
  }
  private excluded(item: DanmakuItem): boolean {
    return this.hidden.has(item.key) || this.ruleMatcher.matches(item);
  }

  /** 规则只在数据到达/已有快照/用户操作时匹配，帧回调不扫描规则或原始分段。 */
  private refillPending(): void {
    if (!this.moving() || this.stream === undefined || this.snapshot === undefined) { return; }
    const media: number = this.media();
    const horizon: number = Math.min(1800, Math.max(650, 600 * Math.max(0.25, this.snapshot.speed)));
    const from: number = Math.max(-1, Math.max(this.lastFrameMedia, media - 150) - 1);
    const loaded: DanmakuItem[] = this.stream.collect(from, media + horizon);
    const filtered: DanmakuItem[] = [];
    for (let index: number = 0; index < loaded.length; index++) {
      const item: DanmakuItem = loaded[index];
      if (!this.recent.has(item.key) && !this.excluded(item)) { filtered.push(item); }
    }
    this.pending = [];
    const count: number = Math.min(MAX_PENDING, filtered.length);
    for (let index: number = 0; index < count; index++) {
      this.pending.push(filtered[Math.floor(index * filtered.length / count)]);
    }
    this.pendingIndex = 0;
  }
  private hasWork(): boolean { return this.tracks.size() > 0 || this.pendingIndex < this.pending.length; }
  private startFrames(): void {
    if (!this.moving() || !this.hasWork() || this.sync !== undefined) { return; }
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      this.sync = sync;
      sync.setExpectedFrameRateRange({ min: 1, max: 60, expected: 60 });
      sync.on('frame', this.frameListener);
      this.pacer.reset();
      sync.start(); this.starts++;
    } catch (_) { this.stopFrames('drawing-error'); this.setStatus('弹幕绘制暂不可用'); }
  }
  private stopFrames(reason: string): void {
    const sync: displaySync.DisplaySync | undefined = this.sync;
    this.sync = undefined;
    if (sync !== undefined) {
      try { sync.stop(); } catch (_) {}
      try { sync.off('frame', this.frameListener); } catch (_) {}
      this.stops++;
      const requests: number = this.stream === undefined ? 0 : this.stream.stats().activeRequests;
      console.info('[PiliMini-dm] stop reason=' + reason + ' frames=' + this.frames.toString() +
        ' starts=' + this.starts.toString() + ' stops=' + this.stops.toString() +
        ' active=' + this.tracks.size().toString() + ' requests=' + requests.toString());
    }
    this.pacer.reset();
  }
  private onFrame(timestampNs: number): void {
    if (!this.moving()) { this.stopFrames('not-running'); return; }
    const now: number = this.now();
    if (now - this.lastSampledAt > 1500) { this.suspend('stale-snapshot'); return; }
    if (!this.pacer.due(timestampNs)) { return; }
    const media: number = this.media();
    while (this.pendingIndex < this.pending.length && this.pending[this.pendingIndex].time <= media) {
      const item: DanmakuItem = this.pending[this.pendingIndex++];
      if (this.recent.has(item.key)) { continue; }
      this.recent.add(item.key); this.recentOrder.push(item.key);
      if (this.recentOrder.length > MAX_RECENT) {
        const old: string | undefined = this.recentOrder.shift();
        if (old !== undefined) { this.recent.delete(old); }
      }
      this.tracks.admit(item, media, (text: string, size: number): number => this.measure(text, size).width);
    }
    this.lastFrameMedia = media;
    this.draw(media); this.frames++;
    if (!this.hasWork()) { this.stopFrames('idle'); }
  }

  private measure(text: string, size: number): MeasuredDanmaku {
    const key: string = size.toString() + ':' + text;
    const found: MeasuredDanmaku | undefined = this.measured.get(key);
    if (found !== undefined) { return found; }
    this.context.font = this.drawFont;
    const metrics: TextMetrics = this.context.measureText(text);
    const value: MeasuredDanmaku = { width: metrics.width,
      left: Number.isFinite(metrics.actualBoundingBoxLeft) ? metrics.actualBoundingBoxLeft : 0,
      right: Number.isFinite(metrics.actualBoundingBoxRight) && metrics.actualBoundingBoxRight > 0 ? metrics.actualBoundingBoxRight : metrics.width,
      ascent: Number.isFinite(metrics.actualBoundingBoxAscent) && metrics.actualBoundingBoxAscent > 0 ? metrics.actualBoundingBoxAscent : size,
      descent: Number.isFinite(metrics.actualBoundingBoxDescent) && metrics.actualBoundingBoxDescent >= 0 ? metrics.actualBoundingBoxDescent : size * 0.25 };
    if (this.measured.size >= MAX_MEASURED) { this.measured.clear(); }
    this.measured.set(key, value);
    return value;
  }

  private closeGlyph(glyph: DanmakuGlyph): void {
    if (glyph.bitmap !== undefined) {
      try { glyph.bitmap.close(); } catch (_) {}
      glyph.bitmap = undefined;
    }
    this.glyphBytes = Math.max(0, this.glyphBytes - glyph.bytes); glyph.bytes = 0;
  }
  private clearGlyphs(): void {
    this.glyphs.forEach((glyph: DanmakuGlyph): void => { this.closeGlyph(glyph); });
    this.glyphs.clear(); this.glyphBytes = 0;
  }
  /** 只在入画时光栅化一次；高密/超长项超出预算仍按原描边绘制，不减条目或清晰度。 */
  private createGlyph(active: ActiveDanmaku): DanmakuGlyph {
    const measured: MeasuredDanmaku = this.measure(active.item.text, active.fontSize);
    const margin: number = this.options.strokeWidth / 2 + 1;
    const scale: number = Math.max(1, vp2px(1));
    const widthPx: number = Math.ceil((measured.left + measured.right + 2 * margin) * scale);
    const heightPx: number = Math.ceil((measured.ascent + measured.descent + 2 * margin) * scale);
    const glyph: DanmakuGlyph = { item: active.item, measured: measured,
      color: this.options.white ? '#FFFFFF' : this.itemColorString(active.item.color), bitmap: undefined,
      left: -measured.left - margin, top: -measured.ascent - margin,
      width: widthPx / scale, height: heightPx / scale, bytes: 0, frame: this.paintRevision };
    const bytes: number = widthPx * heightPx * 4;
    if (!Number.isFinite(bytes) || bytes <= 0 || bytes > MAX_SINGLE_GLYPH_BYTES ||
      this.glyphBytes + bytes > MAX_GLYPH_BYTES) { return glyph; }
    let canvas: OffscreenCanvas | undefined = undefined;
    let bitmap: ImageBitmap | undefined = undefined;
    try {
      canvas = new OffscreenCanvas(glyph.width, glyph.height);
      const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d', new RenderingContextSettings(true));
      ctx.textAlign = 'left'; ctx.textBaseline = 'alphabetic'; ctx.font = this.drawFont;
      // 与原来逐次stroke/fill应用透明度一致，不把二者重叠处改成整组透明度。
      ctx.globalAlpha = this.options.opacity;
      ctx.strokeStyle = '#D9000000'; ctx.lineWidth = this.options.strokeWidth; ctx.lineJoin = 'round';
      ctx.fillStyle = glyph.color;
      ctx.strokeText(active.item.text, -glyph.left, -glyph.top);
      ctx.fillText(active.item.text, -glyph.left, -glyph.top);
      bitmap = canvas.transferToImageBitmap();
      // 默认Canvas/ImageBitmap的宽高都是vp；按实际返回尺寸换算像素，避免仅凭申请尺寸入账。
      const actualWidthPx: number = Math.ceil(bitmap.width * scale);
      const actualHeightPx: number = Math.ceil(bitmap.height * scale);
      const actualBytes: number = actualWidthPx * actualHeightPx * 4;
      if (actualWidthPx > 0 && actualHeightPx > 0 && Number.isFinite(actualBytes) &&
        actualBytes <= MAX_SINGLE_GLYPH_BYTES && this.glyphBytes + actualBytes <= MAX_GLYPH_BYTES) {
        glyph.bitmap = bitmap; glyph.bytes = actualBytes; this.glyphBytes += actualBytes;
      } else { bitmap.close(); }
    } catch (_) {
      if (bitmap !== undefined) { try { bitmap.close(); } catch (_) {} }
    } finally {
      // 释放临时大缓冲；0尺寸会触发系统位图分配错误，保留合法最小画布待局部引用回收。
      if (canvas !== undefined) { canvas.width = 1; canvas.height = 1; }
    }
    return glyph;
  }
  private draw(media: number): void {
    if (!this.ready || this.destroyed) { return; }
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.clearRect(0, 0, this.canvasW, this.canvasH);
    ctx.globalAlpha = 1; ctx.textAlign = 'left'; ctx.textBaseline = 'alphabetic';
    ctx.strokeStyle = '#D9000000'; ctx.lineWidth = this.options.strokeWidth; ctx.lineJoin = 'round';
    ctx.font = this.drawFont;
    const active: ActiveDanmaku[] = this.tracks.frame(media);
    this.paintRevision++;
    // 先释放离场图片，再为新项申请预算；不创建每帧Set或数组。
    for (let index: number = 0; index < active.length; index++) {
      const found: DanmakuGlyph | undefined = this.glyphs.get(active[index].item.key);
      if (found !== undefined) { found.frame = this.paintRevision; }
    }
    this.glyphs.forEach(this.pruneGlyph);
    const margin: number = this.options.strokeWidth / 2 + 1;
    for (let index: number = 0; index < active.length; index++) {
      const item: ActiveDanmaku = active[index];
      let glyph: DanmakuGlyph | undefined = this.glyphs.get(item.item.key);
      if (glyph === undefined) { glyph = this.createGlyph(item); this.glyphs.set(item.item.key, glyph); }
      const measured: MeasuredDanmaku = glyph.measured;
      let painted: PaintedDanmaku;
      if (index < this.painted.length) {
        painted = this.painted[index];
        if (painted.item !== item.item) { painted.color = glyph.color; }
        painted.item = item.item;
      } else {
        painted = { item: item.item, left: 0, right: 0, top: 0, bottom: 0, color: glyph.color };
        this.painted.push(painted);
      }
      if (glyph.bitmap !== undefined) {
        ctx.globalAlpha = 1;
        ctx.drawImage(glyph.bitmap, item.x + glyph.left, item.y + glyph.top, glyph.width, glyph.height);
      } else {
        ctx.globalAlpha = this.options.opacity;
        ctx.fillStyle = glyph.color;
        ctx.strokeText(item.item.text, item.x, item.y); ctx.fillText(item.item.text, item.x, item.y);
      }
      painted.left = item.x - measured.left - margin;
      painted.right = item.x + measured.right + margin;
      painted.top = item.y - measured.ascent - margin;
      painted.bottom = item.y + measured.descent + margin;
    }
    this.painted.length = active.length; // 尾项即时释放原item引用，命中仍严格对应这一帧。
    ctx.globalAlpha = 1;
  }
  private itemColorString(value: number): string {
    return '#' + Math.max(0, Math.min(0xFFFFFF, Math.floor(value))).toString(16).padStart(6, '0');
  }

  private hitTest(x: number, y: number): DanmakuItem | undefined {
    if (!this.allowed() || this.awaitingSnapshot || !Number.isFinite(x) || !Number.isFinite(y) ||
      x < 0 || y < 0 || x > this.canvasW || y > this.canvasH) { return undefined; }
    // 逆绘制顺序，使用最后实际绘制的字形包围盒；暂停不推算未绘制的新位置。
    for (let index: number = this.painted.length - 1; index >= 0; index--) {
      const item: PaintedDanmaku = this.painted[index];
      if (x >= item.left && x <= item.right && y >= item.top && y <= item.bottom) { return copyItem(item.item); }
    }
    return undefined;
  }
  private nearby(): DanmakuItem[] {
    if (!this.allowed() || this.awaitingSnapshot || this.snapshot === undefined || this.snapshot.seeking || this.stream === undefined) { return []; }
    const items: DanmakuItem[] = this.stream.nearby(this.media(), 15000, 120);
    const output: DanmakuItem[] = [];
    for (let index: number = 0; index < items.length; index++) {
      if (!this.excluded(items[index])) { output.push(copyItem(items[index])); }
    }
    return output;
  }
  private hide(key: string): void {
    if (!this.allowed() || key.length === 0) { throw new Error('弹幕暂不可用'); }
    if (!this.hidden.has(key) && this.hidden.size >= MAX_HIDDEN) { throw new Error('本视频隐藏项已达512条，可先恢复隐藏项'); }
    this.hidden.add(key);
    this.refreshFiltered();
  }
  private restoreHidden(): void {
    this.hidden.clear();
    this.refreshFiltered();
  }
  private refreshFiltered(): void {
    if (this.destroyed) { return; }
    this.tracks.removeMatching((item: DanmakuItem): boolean => this.excluded(item));
    if (this.allowed() && !this.awaitingSnapshot) {
      this.refillPending(); this.draw(this.media());
      if (this.moving()) { this.startFrames(); }
    }
  }
  private refreshRules(): void {
    const generation: number = ++this.rulesGeneration;
    DanmakuRuleStore.load().then((rules: DanmakuRule[]): void => {
      if (this.destroyed || generation !== this.rulesGeneration) { return; }
      const first: boolean = !this.rulesReady;
      this.rules = rules; this.ruleMatcher = new DanmakuRuleMatcher(rules); this.rulesReady = true;
      if (first) { this.resumeLatest(); }
      else { this.refreshFiltered(); }
      this.updateStatus();
    }).catch((_error: Error): void => {
      if (!this.destroyed && generation === this.rulesGeneration) { this.setStatus('屏蔽规则加载失败，请重试'); }
    });
  }
  private retry(): void {
    if (!this.rulesReady) { this.refreshRules(); return; }
    if (this.allowed() && this.stream !== undefined) { this.stream.retryCurrent(); this.updateStatus(); }
  }

  build() {
    Canvas(this.context).id('player-danmaku-canvas').width('100%').height('100%').clip(true)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      .onReady((): void => {
        this.ready = true;
        this.updateOptions();
        this.tracks.configure(this.canvasW, this.canvasH, this.options);
        this.resumeLatest();
      })
      .onAreaChange((_old: Area, area: Area): void => {
        const width: number = Number(area.width), height: number = Number(area.height);
        if (Math.abs(width - this.canvasW) < 0.5 && Math.abs(height - this.canvasH) < 0.5) { return; }
        const media: number = this.media();
        const active: DanmakuItem[] = this.activeForReconfigure(media);
        this.canvasW = width; this.canvasH = height;
        this.reconfigure(active, media, 'resize');
      })
  }
}
