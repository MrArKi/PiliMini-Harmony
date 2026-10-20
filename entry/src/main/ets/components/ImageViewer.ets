/**
 * Nara GalleryViewer：透明模态Hero转场、横滑、双击/捏合缩放、拖动及页码。
 * 图片与解码缓存由 AsyncImage 管理，换图复位手势状态。
 */
import { AsyncImage } from './AsyncImage';
import { originalUrl } from '../infra/image/bili_image';
import { image } from '@kit.ImageKit';
import { peekCachedImage } from '../infra/image/image_loader';
import { curves } from '@kit.ArkUI';

export class PreviewRect {
  tag: string = '';
  pixelMap: image.PixelMap | undefined = undefined;
  x: number = 0;
  y: number = 0;
  width: number = 0;
  height: number = 0;
}

@Component
export struct ImageViewer {
  @Prop urls: string[] = [];
  @Prop startIndex: number = 0;
  onClose: () => void = () => {};
  thumbnails: string[] = [];
  sourceRects: PreviewRect[] = [];
  resolveRect: ((index: number) => PreviewRect | undefined) | undefined = undefined;
  thumbW: number = 480;
  thumbH: number = 320;
  registerDismiss: (close: () => void) => void = () => {};
  @State heroX: number = 0;
  @State heroY: number = 0;
  @State heroW: number = 1;
  @State heroH: number = 1;
  @State backdrop: number = 0;
  @State imageOpacity: number = 1;
  @State layoutReady: boolean = false;
  @State inFlight: boolean = true;
  @State flightMap: image.PixelMap | undefined = undefined;
  @State flightThumb: image.PixelMap | undefined = undefined;
  @State flightRadius: number = 4;
  @State pictureX: number = 0;
  @State pictureY: number = 0;
  @State pictureW: number = 1;
  @State pictureH: number = 1;
  @State flightReady: boolean = false;
  private opening: boolean = true;
  private openingStarted: boolean = false;
  private openingFinished: boolean = false;
  private closing: boolean = false;
  private closingStarted: boolean = false;
  private closeRect: PreviewRect | undefined = undefined;
  private displayedMap: image.PixelMap | undefined = undefined;
  private displayedIndex: number = -1;
  private destroyed: boolean = false;
  private originX: number = 0;
  private originY: number = 0;
  @State curIndex: number = 0;
  @State zoom: number = 1;
  @State offX: number = 0;
  @State offY: number = 0;
  @State dragY: number = 0;
  @State dragX: number = 0;
  @State pinching: boolean = false;
  @State viewW: number = 1;
  @State viewH: number = 1;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private zoomBase: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;
  private openedAt: number = 0;
  private lastPanAt: number = 0;
  private imageRatios: Map<number, number> = new Map<number, number>();
  private imageHeights: Map<number, number> = new Map<number, number>();
  private galleryCtrl: SwiperController = new SwiperController();
  private pageDrag: number = 0;
  private dismissDragging: boolean = false;
  private pinchX: number = 0;
  private pinchY: number = 0;
  private flingTimer: number = -1;
  private zoomUntil: number = 0;
  private lastMultiAt: number = 0;
  private pinchBaseX: number = 0;
  private pinchBaseY: number = 0;

  aboutToAppear(): void {
    this.openedAt = Date.now();
    this.curIndex = this.startIndex >= 0 && this.startIndex < this.urls.length ? this.startIndex : 0;
    this.registerDismiss(() => { this.dismiss(); });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.stopFling();
    this.displayedMap = undefined; this.flightMap = undefined; this.flightThumb = undefined;
    AppStorage.setOrCreate<string>('galleryFlightId', '');
  }

  private targetRect(): PreviewRect | undefined {
    const rect: PreviewRect | undefined = this.resolveRect !== undefined ? this.resolveRect(this.curIndex) : this.sourceRects[this.curIndex];
    return rect !== undefined && rect.width > 0 && rect.height > 0 && rect.y < this.viewH + this.originY &&
      rect.y + rect.height > this.originY && rect.x < this.viewW + this.originX &&
      rect.x + rect.width > this.originX ? rect : undefined;
  }

  /** 图片尺寸和裁剪窗分别插值；终点必须与Cover缩略图重合。 */
  private flightGeometry(rect: PreviewRect | undefined): void {
    const w: number = rect !== undefined ? rect.width : this.viewW;
    const h: number = rect !== undefined ? rect.height : this.viewH;
    let ratio: number = this.viewW / this.viewH;
    if (this.flightMap !== undefined) {
      const info: image.ImageInfo = this.flightMap.getImageInfoSync();
      ratio = info.size.width / Math.max(1, info.size.height);
    }
    this.heroX = rect !== undefined ? rect.x - this.originX : 0;
    this.heroY = rect !== undefined ? rect.y - this.originY : 0;
    this.heroW = w; this.heroH = h;
    this.pictureW = rect !== undefined ? Math.max(w, h * ratio) : Math.min(w, h * ratio);
    this.pictureH = this.pictureW / ratio;
    this.pictureX = (w - this.pictureW) / 2;
    this.pictureY = (h - this.pictureH) / 2;
  }

  private prepareFlight(rect: PreviewRect | undefined): void {
    this.flightThumb = rect !== undefined ? rect.pixelMap : undefined;
    this.flightMap = (this.displayedIndex === this.curIndex ? this.displayedMap : undefined) ||
      peekCachedImage(originalUrl(this.urls[this.curIndex]), 2048, 2048, true) || this.flightThumb;
    if (this.flightMap !== undefined) {
      const info: image.ImageInfo = this.flightMap.getImageInfoSync();
      this.imageRatios.set(this.curIndex, info.size.width / Math.max(1, info.size.height));
      this.imageHeights.set(this.curIndex, info.size.height);
    }
  }

  /** 接替图片节点解码就绪后才撤去Hero；syncLoad避免相同PixelMap的异步空帧。 */
  private finishOpening(): void {
    if (!this.openingFinished || this.displayedIndex !== this.curIndex || this.destroyed || this.closing) { return; }
    this.inFlight = false;
    this.flightMap = undefined; this.flightThumb = undefined;
    AppStorage.setOrCreate<string>('galleryFlightId', '');
  }

  private startOpening(): void {
    if (this.openingStarted || !this.layoutReady || this.destroyed || this.closing) { return; }
    this.openingStarted = true;
    this.getUIContext().animateTo({ duration: 300, curve: curves.cubicBezierCurve(0, 0, 0.58, 1),
      onFinish: () => {
        if (this.destroyed || this.closing) { return; }
        this.opening = false; this.openingFinished = true;
        this.finishOpening();
        if (this.isLongPic()) { this.resetZoom(); }
      } }, () => {
      if (this.inFlight) { this.flightGeometry(undefined); }
      this.flightRadius = 0; this.backdrop = 1; this.imageOpacity = 1;
    });
  }

  private startClosing(): void {
    if (this.closingStarted || this.destroyed) { return; }
    this.closingStarted = true;
    this.flightReady = true;
    const rect: PreviewRect | undefined = this.closeRect;
    if (rect !== undefined) { AppStorage.setOrCreate<string>('galleryFlightId', rect.tag); }
    this.getUIContext().animateTo({ duration: 300, curve: curves.cubicBezierCurve(0, 0, 0.58, 1),
      onFinish: () => {
        if (this.destroyed) { return; }
        AppStorage.setOrCreate<string>('galleryFlightId', '');
        this.onClose();
      } }, () => {
      this.backdrop = 0;
      if (rect !== undefined && this.flightThumb !== undefined) {
        this.flightGeometry(rect); this.flightRadius = 4;
      } else { this.imageOpacity = 0; }
    });
  }

  private flightDisplayed(): void {
    if (this.destroyed) { return; }
    if (this.closing) {
      if (this.closeRect !== undefined || this.inFlight) { this.startClosing(); }
    }
    else {
      const rect: PreviewRect | undefined = this.targetRect();
      if (rect !== undefined) { AppStorage.setOrCreate<string>('galleryFlightId', rect.tag); }
      this.startOpening();
    }
  }

  private dismiss(): void {
    if (this.closing || this.destroyed) { return; }
    this.closing = true;
    this.stopFling();
    if (this.opening) {
      // 无图/失败或开场未完成时也能退出；迟到的加载事件不能重新启动开场。
      this.closingStarted = true;
      AppStorage.setOrCreate<string>('galleryFlightId', '');
      this.onClose();
      return;
    }
    // Nara gallery_viewer.dart:492：长图不包Hero，保持顶部阅读位置淡出。
    if (this.isLongPic()) {
      this.getUIContext().animateTo({ duration: 300, curve: curves.cubicBezierCurve(0, 0, 0.58, 1),
        onFinish: () => { if (!this.destroyed) { this.onClose(); } } }, () => {
        this.imageOpacity = 0; this.backdrop = 0;
      });
      return;
    }
    const rect: PreviewRect | undefined = this.targetRect();
    this.prepareFlight(rect);
    this.closeRect = rect;
    if (this.flightMap === undefined) {
      this.getUIContext().animateTo({ duration: 300, curve: curves.cubicBezierCurve(0, 0, 0.58, 1),
        onFinish: () => { if (!this.destroyed) { this.onClose(); } } }, () => {
        this.imageOpacity = 0; this.backdrop = 0;
      });
      return;
    }
    this.flightGeometry(undefined);
    // 从当前缩放/拖动位置接续，不能先跳回未缩放的全屏。
    this.pictureW *= this.zoom * this.dismissScale();
    this.pictureH *= this.zoom * this.dismissScale();
    this.pictureX = (this.viewW - this.pictureW) / 2 + this.offX + this.dragX;
    this.pictureY = (this.viewH - this.pictureH) / 2 + this.offY + this.dragY;
    this.flightRadius = 0; this.flightReady = false; this.inFlight = true;
  }

  private resetZoom(): void {
    this.zoom = this.minimumZoom();
    this.offX = 0;
    this.offY = this.isLongPic() ? Math.max(0, (this.imageSize(false) * this.zoom - this.viewH) / 2) : 0;
    this.dragY = 0;
    this.dragX = 0;
    this.pinching = false;
    this.zoomBase = this.zoom;
    this.baseX = 0;
    this.baseY = 0;
  }

  private imageSize(horizontal: boolean): number {
    const ratio: number = this.imageRatios.get(this.curIndex) || this.viewW / this.viewH;
    return horizontal ? Math.min(this.viewW, this.viewH * ratio) : Math.min(this.viewH, this.viewW / ratio);
  }

  private isLongPic(): boolean {
    return (this.imageRatios.get(this.curIndex) || 1) < 1 / 2.6 &&
      (this.imageHeights.get(this.curIndex) || 0) > this.viewH;
  }
  private minimumZoom(): number {
    return this.isLongPic() ? Math.max(1, Math.min(650, this.viewW) / this.imageSize(true)) : 1;
  }
  private maximumZoom(): number { return Math.max(8, this.minimumZoom() * 3); }
  private atMinimum(): boolean { return this.zoom <= this.minimumZoom() + 0.01; }

  private clampOffset(value: number, horizontal: boolean): number {
    const limit: number = Math.max(0, (this.imageSize(horizontal) * this.zoom - (horizontal ? this.viewW : this.viewH)) / 2);
    return Math.max(-limit, Math.min(value, limit));
  }

  private stopFling(): void {
    if (this.flingTimer !== -1) { clearInterval(this.flingTimer); this.flingTimer = -1; }
  }

  /** 与Nara FrictionSimulation同一指数衰减，边界按图片实际contain尺寸。 */
  private startFling(vx: number, vy: number): void {
    this.stopFling();
    const velocity: number = Math.sqrt(vx * vx + vy * vy);
    if (velocity < 200) { return; }
    const friction: number = velocity > 5000 ? 0.03 : velocity > 3000 ? 0.02 : 0.01;
    const started: number = Date.now();
    let lastDistance: number = 0;
    this.flingTimer = setInterval(() => {
      if (this.destroyed || this.closing) { this.stopFling(); return; }
      const t: number = (Date.now() - started) / 1000;
      const distance: number = velocity * (Math.pow(friction, t) - 1) / Math.log(friction);
      const delta: number = distance - lastDistance;
      lastDistance = distance;
      const x: number = this.clampOffset(this.offX + vx / velocity * delta, true);
      const y: number = this.clampOffset(this.offY + vy / velocity * delta, false);
      if (delta < 0.1 || (x === this.offX && y === this.offY)) { this.stopFling(); return; }
      this.offX = x; this.offY = y;
    }, 16);
  }

  private doubleTap(e: GestureEvent): void {
    if (this.closing || this.opening || Date.now() < this.zoomUntil || Date.now() - this.lastMultiAt < 555) { return; }
    this.zoomUntil = Date.now() + 555;
    this.stopFling();
    if (!this.atMinimum()) { animateTo({ duration: 300, curve: curves.cubicBezierCurve(0, 0, 0.58, 1) }, () => { this.resetZoom(); }); return; }
    const x: number = e.fingerList.length > 0 ? e.fingerList[0].localX : this.viewW / 2;
    const y: number = e.fingerList.length > 0 ? e.fingerList[0].localY : this.viewH / 2;
    animateTo({ duration: 300, curve: curves.cubicBezierCurve(0, 0, 0.58, 1) }, () => {
      const factor: number = this.maximumZoom() * 0.6 / this.zoom;
      const xBefore: number = this.offX, yBefore: number = this.offY;
      this.zoom = this.maximumZoom() * 0.6;
      this.zoomBase = this.zoom;
      this.offX = this.clampOffset(xBefore * factor + (this.viewW / 2 - x) * (factor - 1), true);
      this.offY = this.clampOffset(yBefore * factor + (this.viewH / 2 - y) * (factor - 1), false);
    });
  }

  private dismissScale(): number {
    return 1 - Math.min(1, Math.abs(this.dragY) / this.viewH) * 0.75;
  }

  @Builder
  Picture(url: string, index: number) {
    Column() {
      if (index === this.curIndex) {
        AsyncImage({ src: originalUrl(url), w: 2048, h: 2048, original: true, fit: ImageFit.Contain,
        placeholder: Color.Transparent, previewSrc: this.thumbnails[index] || '',
        previewW: this.thumbW, previewH: this.thumbH, synchronous: true,
        previewMap: this.sourceRects[index] !== undefined ? this.sourceRects[index].pixelMap : undefined,
        onDisplayed: (pm: image.PixelMap) => {
          if (index !== this.curIndex || this.destroyed) { return; }
          this.displayedMap = pm; this.displayedIndex = index;
          if (!this.inFlight && this.opening) { this.startOpening(); }
          this.finishOpening();
        },
        onImageSize: (w: number, h: number) => {
          if (h <= 0) { return; }
          const first: boolean = !this.imageRatios.has(index);
          this.imageRatios.set(index, w / h); this.imageHeights.set(index, h);
          if (first && index === this.curIndex && this.isLongPic() && !this.closing && !this.opening) { this.resetZoom(); }
        } })
      } else {
        // 滑动预览邻页只复用小图，尚未观看的原图不预取。
        AsyncImage({ src: this.thumbnails[index] || url, w: this.thumbW, h: this.thumbH,
          fit: ImageFit.Contain, placeholder: Color.Transparent })
      }
    }
    .width('100%')
    .height('100%')
    .scale({
      x: index === this.curIndex ? this.zoom * this.dismissScale() : 1,
      y: index === this.curIndex ? this.zoom * this.dismissScale() : 1
    })
    .translate({ x: index === this.curIndex ? this.offX + this.dragX : 0,
      y: index === this.curIndex ? this.offY + this.dragY : 0 })

  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#000000')
        .opacity(this.backdrop * (1 - Math.min(1, Math.abs(this.dragY) / this.viewH)))
        .hitTestBehavior(HitTestMode.None)
      Swiper(this.galleryCtrl) {
        ForEach(this.urls, (url: string, index: number) => {
          if (Math.abs(index - this.curIndex) <= 1) { this.Picture(url, index) }
          else { Column().width('100%').height('100%') }
        }, (url: string, index: number) => index.toString() + '_' + url)
      }
      .width(this.viewW)
      .height(this.viewH)
      .position({ left: 0, top: 0 })
      .opacity(this.inFlight && (!this.closing || this.flightReady) ? 0 : this.imageOpacity)
      .index(this.curIndex)
      .loop(false)
      .indicator(false)
      .cachedCount(0)
      .duration(200)
      .curve(Curve.Ease)
      .disableSwipe(!this.atMinimum() || this.pinching || Math.abs(this.dragY) > 5)
      .onChange((index: number) => {
        this.stopFling(); this.displayedMap = undefined; this.displayedIndex = -1;
        this.curIndex = index; this.resetZoom();
      })
    .parallelGesture(GestureGroup(GestureMode.Parallel,
      GestureGroup(GestureMode.Exclusive,
      TapGesture({ count: 2 }).onAction((e: GestureEvent) => { this.doubleTap(e); }),
      TapGesture({ count: 1 }).onAction(() => {
        if (Date.now() - this.openedAt >= 300 && Date.now() - this.lastPanAt > 400 &&
          Date.now() - this.lastMultiAt > 555) { this.dismiss(); }
      })
      ),
      PinchGesture({ fingers: 2 })
        .onActionStart((e: GestureEvent) => {
          this.stopFling();
          this.lastMultiAt = Date.now();
          this.pinching = true;
          this.zoomBase = this.zoom;
          this.pinchBaseX = this.offX; this.pinchBaseY = this.offY;
          this.pinchX = e.pinchCenterX - this.viewW / 2;
          this.pinchY = e.pinchCenterY - this.viewH / 2;
          this.dragY = 0; this.dragX = 0;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.zoom = Math.max(this.minimumZoom(), Math.min(this.zoomBase * e.scale, this.maximumZoom()));
          const factor: number = this.zoom / this.zoomBase;
          this.lastMultiAt = Date.now();
          this.offX = this.clampOffset(e.pinchCenterX - this.viewW / 2 - (this.pinchX - this.pinchBaseX) * factor, true);
          this.offY = this.clampOffset(e.pinchCenterY - this.viewH / 2 - (this.pinchY - this.pinchBaseY) * factor, false);
        })
        .onActionEnd(() => {
          this.lastMultiAt = Date.now();
          this.pinching = false;
          this.zoomBase = this.zoom;
          if (this.atMinimum()) { this.offX = this.clampOffset(this.offX, true); this.offY = this.clampOffset(this.offY, false); }
        })
        .onActionCancel(() => { this.lastMultiAt = Date.now(); this.pinching = false; }),
      PanGesture({ direction: PanDirection.All, distance: 5 })
        .onActionStart(() => {
          this.stopFling(); this.lastPanAt = Date.now(); this.baseX = this.offX; this.baseY = this.offY;
          this.pageDrag = 0; this.dismissDragging = false;
        })
        .onActionUpdate((e: GestureEvent) => {
          if (this.pinching) { return; }
          if (this.atMinimum() && Math.abs(e.offsetY) > Math.abs(e.offsetX) &&
            (!this.isLongPic() || (e.offsetY > 0 && this.baseY >= this.clampOffset(1e9, false) - 1) ||
              (e.offsetY < 0 && this.baseY <= this.clampOffset(-1e9, false) + 1))) {
            this.dismissDragging = true;
          }
          if (this.dismissDragging) {
            this.dragY = e.offsetY;
            this.dragX = e.offsetX * this.viewW / this.viewH;
          } else if (!this.atMinimum() || this.isLongPic()) {
            this.offX = this.clampOffset(this.baseX + e.offsetX, true);
            this.offY = this.clampOffset(this.baseY + e.offsetY, false);
            if (!this.atMinimum() && Math.abs(e.offsetX) > Math.abs(e.offsetY) * 1.2) {
              this.pageDrag = this.baseX + e.offsetX - this.offX;
            }
          }
        })
        .onActionEnd((e: GestureEvent) => {
          this.lastPanAt = Date.now();
          if (this.pinching || Date.now() - this.lastMultiAt < 200) { this.dragY = 0; this.dragX = 0; return; }
          if (Math.abs(this.pageDrag) > this.viewW * 0.2) {
            const next: number = Math.max(0, Math.min(this.urls.length - 1, this.curIndex + (this.pageDrag < 0 ? 1 : -1)));
            if (next !== this.curIndex) { this.galleryCtrl.changeIndex(next, true); return; }
          }
          if (!this.dismissDragging && (!this.atMinimum() || this.isLongPic())) { this.startFling(e.velocityX, e.velocityY); return; }
          if (!this.pinching && Math.abs(this.dragY) / this.viewH > 0.2) {
            this.dismiss();
          } else {
            animateTo({ duration: Math.max(1, Math.round(750 * Math.min(0.2, Math.abs(this.dragY) / this.viewH))), curve: Curve.Linear },
              () => { this.dragY = 0; this.dragX = 0; });
          }
        })
        .onActionCancel(() => { this.dragY = 0; this.dragX = 0; })
    ))

      if (this.inFlight) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.flightMap !== undefined) {
            Image(this.flightMap).width(this.pictureW).height(this.pictureH).objectFit(ImageFit.Fill)
              .position({ x: this.pictureX, y: this.pictureY })
              .syncLoad(true)
              .onComplete((event) => {
                if (event !== undefined && event.loadingStatus === 1) { this.flightDisplayed(); }
              })
          }
        }
        .width(this.heroW).height(this.heroH).position({ x: this.heroX, y: this.heroY })
        .borderRadius(this.flightRadius).clip(true).opacity(this.imageOpacity).hitTestBehavior(HitTestMode.None)
      }

      Row() {
        Text((this.curIndex + 1).toString() + '/' + this.urls.length.toString())
          .fontSize(14)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .height(this.statusBarH + this.navBarH + 36)
      .padding({ left: 12, right: 20, top: this.statusBarH + 8, bottom: this.navBarH + 8 })
      .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#4D000000', 1]] })
      .position({ left: 0, bottom: 0 })
      .hitTestBehavior(HitTestMode.None)
      .opacity(this.backdrop)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .opacity(this.layoutReady ? 1 : 0)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) { this.stopFling(); }
      if (event.touches.length > 1) { this.lastMultiAt = Date.now(); }
    })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.viewW = Math.max(1, Number(newArea.width));
      this.viewH = Math.max(1, Number(newArea.height));
      this.originX = Number(newArea.globalPosition.x); this.originY = Number(newArea.globalPosition.y);
      if (!this.layoutReady) {
        const rect: PreviewRect | undefined = this.targetRect();
        this.prepareFlight(rect);
        if (this.isLongPic()) {
          this.inFlight = false; this.imageOpacity = 0; this.resetZoom();
        } else {
          this.flightGeometry(rect);
        }
        this.layoutReady = true;
        // 普通图由Hero解码完成事件启动；无源图只能淡入，不隐藏底页缩略图。
        if (this.flightMap === undefined) { this.inFlight = false; }
        if (!this.inFlight && this.displayedIndex === this.curIndex) { this.startOpening(); }
      }
    })
  }
}
