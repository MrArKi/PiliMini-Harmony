/** Nara HeroDialogRoute语义：透明模态层保留底页，返回当前缩略图，绝不切播放器路由。 */
import { AsyncImage } from './AsyncImage';
import { ImageViewer, PreviewRect } from './ImageViewer';
import { image } from '@kit.ImageKit';
import { originalUrl } from '../infra/image/bili_image';
import { peekCachedImage } from '../infra/image/image_loader';
import { common } from '@kit.AbilityKit';
import { refreshSystemBars } from '../infra/player/system_bars';

let gallerySequence: number = 0;
export function nextGalleryId(): string { return 'gallery_' + (++gallerySequence).toString(); }

@CustomDialog
struct GalleryDialog {
  controller: CustomDialogController;
  urls: string[] = [];
  thumbs: string[] = [];
  rects: PreviewRect[] = [];
  resolveRect: (index: number) => PreviewRect | undefined = () => undefined;
  startIndex: number = 0;
  thumbW: number = 480;
  thumbH: number = 320;
  onDone: () => void = () => {};
  registerDismiss: (close: () => void) => void = () => {};

  build() {
    ImageViewer({ urls: this.urls, startIndex: this.startIndex, thumbnails: this.thumbs,
      sourceRects: this.rects, resolveRect: this.resolveRect, thumbW: this.thumbW, thumbH: this.thumbH,
      onClose: this.onDone, registerDismiss: this.registerDismiss })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

@Component
export struct GalleryThumbnail {
  @Prop urls: string[] = [];
  @Prop thumbs: string[] = [];
  @Prop index: number = 0;
  @Prop groupId: string = '';
  @Prop w: number = 480;
  @Prop h: number = 320;
  @StorageProp('galleryFlightId') flightId: string = '';
  private displayedMap: image.PixelMap | undefined = undefined;
  private dialog: CustomDialogController | undefined = undefined;
  private dismissViewer: (() => void) | undefined = undefined;

  private close(): void {
    if (this.dialog !== undefined) {
      this.dialog.close(); this.dialog = undefined;
      AppStorage.setOrCreate<boolean>('imagePreviewVisible', false);
      AppStorage.setOrCreate<string>('galleryFlightId', '');
      refreshSystemBars(getContext(this) as common.UIAbilityContext);
    }
    this.dismissViewer = undefined;
  }
  aboutToDisappear(): void { this.close(); this.displayedMap = undefined; }

  /** 不用服务器1c裁成固定宽高：缩略图必须保留原图内容，Cover裁剪交给布局。 */
  private previewUrls(): string[] {
    return this.urls.map((url: string) => originalUrl(url) + '@' + this.w.toString() + 'w.webp');
  }

  private measure(index: number): PreviewRect | undefined {
    const rect: PreviewRect = new PreviewRect();
    rect.tag = this.groupId + '_' + index.toString();
    try {
      const bounds = this.getUIContext().getComponentUtils().getRectangleById(rect.tag);
      rect.x = px2vp(bounds.windowOffset.x); rect.y = px2vp(bounds.windowOffset.y);
      rect.width = px2vp(bounds.size.width); rect.height = px2vp(bounds.size.height);
      rect.pixelMap = index === this.index ? this.displayedMap :
        peekCachedImage(this.previewUrls()[index], this.w, 2048);
      return rect;
    } catch (error) { return undefined; }
  }

  private open(): void {
    if (this.dialog !== undefined || this.urls.length === 0) { return; }
    const rects: PreviewRect[] = [];
    for (let i: number = 0; i < this.urls.length; i++) { rects.push(this.measure(i) || new PreviewRect()); }
    this.dialog = new CustomDialogController({
      builder: GalleryDialog({ urls: this.urls, thumbs: this.previewUrls(), rects: rects,
        startIndex: this.index, resolveRect: (index: number) => this.measure(index), thumbW: this.w, thumbH: 2048,
        onDone: () => { this.close(); },
        registerDismiss: (close: () => void) => { this.dismissViewer = close; } }),
      customStyle: true, alignment: DialogAlignment.Center, autoCancel: false,
      // mask仅控制遮罩；内容底板也必须透明，避免深色主题弹窗黑底抢占首尾帧。
      backgroundColor: Color.Transparent, backgroundBlurStyle: BlurStyle.NONE, maskColor: Color.Transparent,
      openAnimation: { duration: 0 }, closeAnimation: { duration: 0 },
      onWillDismiss: () => { if (this.dismissViewer !== undefined) { this.dismissViewer(); } }
    });
    this.dialog.open();
    AppStorage.setOrCreate<boolean>('imagePreviewVisible', true);
    refreshSystemBars(getContext(this) as common.UIAbilityContext);
  }

  build() {
    AsyncImage({ src: this.previewUrls()[this.index], w: this.w, h: 2048,
      onReady: (pm: image.PixelMap) => { this.displayedMap = pm; } })
      .id(this.groupId + '_' + this.index.toString())
      .opacity(this.flightId === this.groupId + '_' + this.index.toString() ? 0 : 1)
      .onClick(() => { this.open(); })
  }
}
