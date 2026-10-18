/**
 * 异步图片组件（spec-02 任务 2.4）
 * 使用时自动走 ImageLoader 两级缓存
 */
import { image } from '@kit.ImageKit';
import { loadImage, peekCachedImage } from '../infra/image/image_loader';

@Component
export struct AsyncImage {
  @Prop @Watch('onSrcChange') src: string = '';
  @Prop w: number = 480;
  @Prop h: number = 270;
  /** 仅查看器按需原图；原图不进入磁盘缓存。 */
  @Prop original: boolean = false;
  /** 显示模式：列表默认 Cover；查看器用 Contain */
  @Prop fit: ImageFit = ImageFit.Cover;
  @Prop placeholder: ResourceColor = $r('app.color.btn_soft_bg');
  /** 大图加载复用已显示缩略图，避免黑底预览期间闪白。 */
  @Prop previewSrc: string = '';
  @Prop previewW: number = 480;
  @Prop previewH: number = 320;
  onImageSize: (w: number, h: number) => void = () => {};
  onReady: (pm: image.PixelMap) => void = () => {};
  @State pixelMap: image.PixelMap | undefined = undefined;
  private destroyed: boolean = false;

  aboutToAppear(): void {
    this.destroyed = false;
    this.fetch();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.pixelMap = undefined;
  }

  onSrcChange(): void {
    this.pixelMap = undefined;
    this.fetch();
  }

  private fetch(): void {
    if (this.src.length === 0) {
      return;
    }
    const want: string = this.src;
    this.pixelMap = peekCachedImage(this.src, this.w, this.h, this.original) ||
      peekCachedImage(this.previewSrc, this.previewW, this.previewH);
    if (this.pixelMap !== undefined) { this.onReady(this.pixelMap); }
    if (this.previewSrc.length > 0) {
      loadImage(this.previewSrc, this.previewW, this.previewH).then((pm: image.PixelMap) => {
        if (!this.destroyed && this.src === want && this.pixelMap === undefined) { this.pixelMap = pm; this.onReady(pm); }
      }).catch(() => {});
    }
    loadImage(this.src, this.w, this.h, this.original).then((pm: image.PixelMap) => {
      // 组件已销毁或 src 已变化（LazyForEach 复用）：丢弃过期结果
      if (this.destroyed || this.src !== want) {
        return;
      }
      this.pixelMap = pm;
      this.onReady(pm);
      const info: image.ImageInfo = pm.getImageInfoSync();
      this.onImageSize(info.size.width, info.size.height);
    }).catch((e: Error) => {
      console.warn('[AsyncImage] 加载失败: ' + e.message);
    });
  }

  build() {
    Column() {
      if (this.pixelMap !== undefined) {
        Image(this.pixelMap)
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.placeholder)
      }
    }
    .width('100%')
    .height('100%')
  }
}
