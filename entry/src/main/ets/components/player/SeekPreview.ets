import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { FrameCallback } from '@kit.ArkUI';
import { VideoShotData, VideoShotFrame, videoShotFrameAt } from '../../model/video_shot';
import { VideoShotService } from '../../service/video_shot_service';
import { CookieStore } from '../../infra/cookie/cookie_store';

/** 渲染树移除旧小图之后释放，避免ArkUI仍在绘制时回收PixelMap。 */
class ReleaseSeekFrame extends FrameCallback {
  private frame: image.PixelMap | undefined;
  private fallback: number = -1;
  constructor(frame: image.PixelMap) {
    super(); this.frame = frame;
    // 页面退场/后台可能没有后续绘制；单次兜底不依赖已销毁组件继续收帧。
    this.fallback = setTimeout((): void => { this.release(); }, 250);
  }
  onIdle(): void { this.release(); }
  private release(): void {
    if (this.fallback !== -1) { clearTimeout(this.fallback); this.fallback = -1; }
    const old: image.PixelMap | undefined = this.frame; this.frame = undefined;
    if (old) { old.release().catch((): void => {}); }
  }
}

/** Nara中心快照：每次拖动才联网，单压缩页+串行裁切，不创建第二个播放器。 */
@Component
export struct SeekPreview {
  @Prop @Watch('resetSource') bvid: string = '';
  @Prop @Watch('resetSource') cid: number = 0;
  @Prop @Watch('activeChanged') active: boolean = false;
  /** 前台可见才保留一张压缩页；松手只取消请求与裁切图，不重复下载同页。 */
  @Prop @Watch('cacheAllowedChanged') cacheAllowed: boolean = true;
  @Prop @Watch('positionChanged') positionMs: number = 0;
  @Prop playerWidth: number = 360;
  @Prop playerHeight: number = 200;
  @Prop fullscreen: boolean = false;
  @Prop vertical: boolean = false;
  @State private frame: image.PixelMap | undefined = undefined;
  @State private failed: boolean = false;
  @State private ratio: number = 16 / 9;
  private metadata: VideoShotData | undefined = undefined;
  private sheet: ArrayBuffer | undefined = undefined;
  private sheetPage: number = -1;
  private currentIndex: number = -1;
  private generation: number = 0;
  private sessionRevision: number = CookieStore.sessionRevision();
  private busy: boolean = false;
  private destroyed: boolean = false;
  private request: http.HttpRequest | undefined = undefined;

  aboutToAppear(): void { this.pump(); }
  aboutToDisappear(): void { this.destroyed = true; this.cancel(true); this.metadata = undefined; }

  private releaseFrame(): void {
    const old: image.PixelMap | undefined = this.frame;
    this.frame = undefined; this.currentIndex = -1;
    if (old) {
      const release: ReleaseSeekFrame = new ReleaseSeekFrame(old);
      try { this.getUIContext().postFrameCallback(release); } catch (_) { /* 单次兜底负责回收。 */ }
    }
  }

  private cancel(clearSheet: boolean = false): void {
    this.generation++;
    this.request?.destroy(); this.request = undefined;
    if (clearSheet) { this.sheet = undefined; this.sheetPage = -1; }
    this.releaseFrame();
  }

  private resetSource(): void {
    this.cancel(true); this.metadata = undefined; this.failed = false; this.ratio = 16 / 9;
    this.sessionRevision = CookieStore.sessionRevision();
    this.pump();
  }

  private activeChanged(): void {
    if (!this.active) { this.cancel(!this.cacheAllowed); }
    else { this.failed = false; this.pump(); }
  }

  private cacheAllowedChanged(): void {
    if (!this.cacheAllowed) { this.cancel(true); }
    else if (this.active) { this.pump(); }
  }

  private positionChanged(): void { this.pump(); }
  private valid(generation: number): boolean {
    return !this.destroyed && this.cacheAllowed && this.active && generation === this.generation &&
      this.sessionRevision === CookieStore.sessionRevision();
  }

  private pump(): void {
    if (this.destroyed || !this.cacheAllowed || !this.active) { return; }
    if (this.sessionRevision !== CookieStore.sessionRevision()) { this.resetSource(); return; }
    if (this.busy || this.failed ||
      !/^BV[A-Za-z0-9]+$/.test(this.bvid) || this.cid <= 0) { return; }
    if (this.metadata && videoShotFrameAt(this.metadata, this.positionMs / 1000).index === this.currentIndex) { return; }
    this.busy = true;
    const generation: number = this.generation;
    this.decodeLatest(generation).catch((): void => {
      if (this.valid(generation)) { this.failed = true; this.releaseFrame(); }
    }).finally((): void => {
      this.busy = false;
      if (!this.destroyed && this.active && !this.failed) { this.pump(); }
    });
  }

  private async decodeLatest(generation: number): Promise<void> {
    if (!this.metadata) {
      const request: http.HttpRequest = http.createHttp(); this.request = request;
      try {
        const data: VideoShotData = await VideoShotService.load(this.bvid, this.cid, request,
          (): boolean => this.valid(generation));
        if (!this.valid(generation)) { return; }
        this.metadata = data;
        if (data.frameWidth > 0 && data.frameHeight > 0) { this.ratio = data.frameWidth / data.frameHeight; }
      } finally { if (this.request === request) { this.request = undefined; } request.destroy(); }
    }
    while (this.valid(generation) && this.metadata) {
      const data: VideoShotData = this.metadata;
      const selection: VideoShotFrame = videoShotFrameAt(data, this.positionMs / 1000);
      if (selection.index === this.currentIndex) { return; }
      if (this.currentIndex >= 0 && Math.floor(this.currentIndex / (data.columns * data.rows)) !== selection.page) {
        this.releaseFrame();
      }
      if (!this.sheet || this.sheetPage !== selection.page) {
        this.sheet = undefined; this.sheetPage = -1;
        const request: http.HttpRequest = http.createHttp(); this.request = request;
        try {
          const bytes: ArrayBuffer = await VideoShotService.loadSheet(data.images[selection.page], request);
          if (!this.valid(generation)) { return; }
          this.sheet = bytes; this.sheetPage = selection.page;
        } finally { if (this.request === request) { this.request = undefined; } request.destroy(); }
        // 网络期间可能越过另一张雪碧图；只解码最新目标，过时页不出图。
        if (videoShotFrameAt(data, this.positionMs / 1000).page !== selection.page) { continue; }
      }
      const latest: VideoShotFrame = videoShotFrameAt(data, this.positionMs / 1000);
      const bytes: ArrayBuffer | undefined = this.sheet;
      if (!bytes) { return; }
      if (latest.page !== this.sheetPage) { continue; }
      const source: image.ImageSource = image.createImageSource(bytes);
      let decoded: image.PixelMap | undefined = undefined;
      try {
        const info: image.ImageInfo = await source.getImageInfo();
        if (!this.valid(generation)) { return; }
        const width: number = Math.floor(data.frameWidth > 0 ? data.frameWidth : info.size.width / data.columns);
        const height: number = Math.floor(data.frameHeight > 0 ? data.frameHeight : info.size.height / data.rows);
        if (width <= 0 || height <= 0 || (latest.column + 1) * width > info.size.width ||
          (latest.row + 1) * height > info.size.height || info.size.width * info.size.height > 32000000) {
          throw new Error('预览图片尺寸无效');
        }
        const scale: number = Math.min(1, 320 / width, 180 / height);
        decoded = await source.createPixelMap({
          desiredRegion: { x: latest.column * width, y: latest.row * height, size: { width: width, height: height } },
          desiredSize: { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) },
          cropAndScaleStrategy: image.CropAndScaleStrategy.CROP_FIRST
        });
        if (!this.valid(generation) || this.sheetPage !== latest.page ||
          videoShotFrameAt(data, this.positionMs / 1000).page !== latest.page) {
          decoded.release().catch((): void => {}); decoded = undefined; continue;
        }
        // 同页持续拖动可先显示本次刚完成的小图；下一轮仍追最新索引，避免首图被反复丢弃。
        this.releaseFrame(); this.frame = decoded; decoded = undefined;
        this.currentIndex = latest.index; this.ratio = width / height;
      } finally { await source.release(); if (decoded) { decoded.release().catch((): void => {}); } }
    }
  }

  private previewHeight(): number {
    const base: number = this.fullscreen && !this.vertical ? 108 : 81;
    const compat: number = this.playerHeight - 140;
    return compat > 50 ? Math.min(base, compat) : base;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.active && !this.failed && this.frame !== undefined) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.frame).id('player-seek-preview-image').width('100%').height('100%').objectFit(ImageFit.Fill)
        }
        .width(Math.min(this.playerWidth, this.previewHeight() * this.ratio)).height(this.previewHeight())
        .backgroundColor('#94000000').borderRadius(10).clip(true)
        .border({ width: 1.5, color: '#FFFFFF' })
      }
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
  }
}
