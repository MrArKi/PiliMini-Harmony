/**
 * 官方共享元素隔离探针：两个NavDestination、同一封面PixelMap、双向300ms。
 * 路由 pages/debug/HeroSpike；不挂播放器、不写账号或播放进度。
 * 依据：spec-33-官方探针记录.md；默认系统push/pop转场在每次操作中显式关闭。
 */
import { curves } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { FrameCallback } from '@ohos.arkui.UIContext';
import { loadImage, peekCachedImage } from '../../infra/image/image_loader';

const HERO_DURATION: number = 300;
const HERO_SLOW_DURATION: number = 1500;
const HERO_CURVE: ICurve = curves.cubicBezierCurve(0.28, 0.70, 0.12, 1);
// 公开av170001封面；不请求视频详情、Cookie或播放源。
const HERO_COVER: string = 'https://i2.hdslb.com/bfs/archive/1ada8c32a9d168e4b2ee3e010f24789ba3353785.jpg';
const HERO_IMAGE_W: number = 960;
const HERO_IMAGE_H: number = 540;

class HeroFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_time: number): void { this.action(); this.action = () => {}; }
}

class HeroItem {
  id: string;
  title: string;
  ratio: number;
  constructor(id: string, title: string, ratio: number) {
    this.id = id; this.title = title; this.ratio = ratio;
  }
}

@Entry
@Component
struct HeroSpike {
  private stack: NavPathStack = new NavPathStack();
  private items: HeroItem[] = [
    new HeroItem('a', '左上 · 16:9', 16 / 9),
    new HeroItem('b', '右上 · 4:3', 4 / 3),
    new HeroItem('c', '左中 · 1:1', 1),
    new HeroItem('d', '右中 · 16:9', 16 / 9),
    new HeroItem('e', '左下 · 4:3', 4 / 3),
    new HeroItem('f', '右下 · 1:1', 1)
  ];
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  @State pixel: image.PixelMap | undefined = undefined;
  @State loading: boolean = true;
  @State loadError: boolean = false;
  @State slow: boolean = false;
  @State imageOnly: boolean = false;
  @State removeSource: boolean = false;
  @State fitMode: number = 0;
  @State selected: string = '';
  @State busy: boolean = false;
  @State sourceReady: string[] = [];
  private destroyed: boolean = false;
  private bootQueued: boolean = false;
  private detailDisplayed: boolean = false;

  aboutToAppear(): void {
    this.destroyed = false;
    this.loadCover();
  }

  aboutToDisappear(): void { this.destroyed = true; }

  /** Navigation挂载后的下一帧才推根Destination，不在aboutToAppear改空栈。 */
  private mountRoot(): void {
    if (this.bootQueued) { return; }
    this.bootQueued = true;
    this.getUIContext().postFrameCallback(new HeroFrame((): void => {
      if (!this.destroyed && this.stack.size() === 0) {
        this.stack.pushPath({ name: 'spikeList' }, false);
        console.info('[HeroSpike] root=NavDestination navBar=hidden');
      }
    }));
  }

  private async loadCover(): Promise<void> {
    this.loading = true; this.loadError = false;
    try {
      const cached: image.PixelMap | undefined = peekCachedImage(HERO_COVER, HERO_IMAGE_W, HERO_IMAGE_H);
      const pixel: image.PixelMap = cached === undefined ? await loadImage(HERO_COVER, HERO_IMAGE_W, HERO_IMAGE_H) : cached;
      if (!this.destroyed) {
        this.pixel = pixel;
        console.info('[HeroSpike] pixels=ready cache=' + (cached === undefined ? '0' : '1'));
      }
    } catch (_) {
      if (!this.destroyed) { this.loadError = true; console.warn('[HeroSpike] pixels=failed'); }
    } finally { if (!this.destroyed) { this.loading = false; } }
  }

  private duration(): number { return this.slow ? HERO_SLOW_DURATION : HERO_DURATION; }
  private fit(): RenderFit {
    if (this.fitMode === 1) { return RenderFit.RESIZE_CONTAIN; }
    if (this.fitMode === 2) { return RenderFit.RESIZE_COVER_TOP_LEFT; }
    return RenderFit.RESIZE_COVER;
  }

  private geometryId(id: string, imageNode: boolean): string {
    return this.imageOnly === imageNode ? 'spike_shared_' + id : '';
  }

  private itemOf(param: object): HeroItem {
    const value: HeroItem = param as HeroItem;
    const id: string = value === undefined || value === null || typeof value.id !== 'string' ? '' : value.id;
    for (let i: number = 0; i < this.items.length; i++) {
      if (this.items[i].id === id) { return this.items[i]; }
    }
    return this.items[0];
  }

  private reportSource(id: string): void {
    if (this.destroyed || this.sourceReady.indexOf(id) >= 0) { return; }
    this.sourceReady = this.sourceReady.concat([id]);
    console.info('[HeroSpike] sourceDisplayed=' + id);
  }

  private openItem(item: HeroItem): void {
    if (this.busy || this.pixel === undefined || this.sourceReady.indexOf(item.id) < 0 || this.stack.size() !== 1) { return; }
    this.busy = true; this.detailDisplayed = false;
    console.info('[HeroSpike] push id=' + item.id + ' ms=' + this.duration().toString() +
      ' bind=' + (this.imageOnly ? 'image' : 'container') + ' ifRemove=' + (this.removeSource ? '1' : '0') +
      ' renderFit=' + this.fitMode.toString() + ' animated=0');
    this.getUIContext().animateTo({ duration: this.duration(), curve: HERO_CURVE,
      onFinish: (): void => { if (!this.destroyed) { this.busy = false; console.info('[HeroSpike] push=finished'); } }
    }, (): void => {
      this.selected = item.id;
      this.stack.pushPath({ name: 'spikeDetail', param: item }, false);
    });
  }

  private closeDetail(): void {
    if (this.busy || this.stack.size() <= 1) { return; }
    this.busy = true;
    console.info('[HeroSpike] pop id=' + this.selected + ' ms=' + this.duration().toString() + ' animated=0');
    this.getUIContext().animateTo({ duration: this.duration(), curve: HERO_CURVE,
      onFinish: (): void => { if (!this.destroyed) { this.busy = false; console.info('[HeroSpike] pop=finished'); } }
    }, (): void => {
      this.selected = '';
      this.stack.pop(false);
    });
  }

  onBackPress(): boolean {
    if (this.stack.size() > 1) { this.closeDetail(); return true; }
    return false;
  }

  /** 共享属性在图片或裁剪容器中二选一，一次只有一对相同ID。 */
  @Builder
  SharedCover(item: HeroItem, detail: boolean) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.pixel !== undefined) {
        Image(this.pixel)
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .autoResize(false).syncLoad(true)
          .borderRadius(this.imageOnly && !detail ? 12 : 0).clip(true)
          .renderFit(this.imageOnly ? this.fit() : RenderFit.RESIZE_FILL)
          .geometryTransition(this.geometryId(item.id, true))
          .transition(TransitionEffect.opacity(1))
          .id(detail ? 'spike_detail_image' : 'spike_image_' + item.id)
          .onComplete((event): void => {
            if (event === undefined || event.loadingStatus !== 1 || this.destroyed) { return; }
            if (!detail) { this.reportSource(item.id); }
            else if (!this.detailDisplayed) {
              this.detailDisplayed = true;
              console.info('[HeroSpike] detailDisplayed=' + item.id + ' samePixel=1');
            }
          })
      }
      Text(item.id.toUpperCase())
        .fontSize(12).fontColor(Color.White)
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .backgroundColor('#99000000').borderRadius(4).margin(8)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Black)
    .borderRadius(!this.imageOnly && !detail ? 12 : 0).clip(!this.imageOnly)
    .renderFit(this.imageOnly ? RenderFit.RESIZE_FILL : this.fit())
    .geometryTransition(this.geometryId(item.id, false))
    .transition(TransitionEffect.opacity(1))
    .id(detail ? 'spike_detail_shared' : 'spike_shared_' + item.id)
  }

  @Builder
  Controls() {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Button(this.slow ? '慢放 1500ms' : '正式 300ms')
          .fontSize(11).height(30).layoutWeight(1)
          .id('spike_speed_toggle').onClick((): void => { if (!this.busy) { this.slow = !this.slow; } })
        Button(this.imageOnly ? '共享：图片' : '共享：容器')
          .fontSize(11).height(30).layoutWeight(1)
          .id('spike_binding_toggle').onClick((): void => { if (!this.busy) { this.imageOnly = !this.imageOnly; } })
      }.width('100%')
      Row({ space: 8 }) {
        Button(this.removeSource ? '源图：if出树' : '源图：保留树')
          .fontSize(11).height(30).layoutWeight(1)
          .id('spike_source_toggle').onClick((): void => { if (!this.busy) { this.removeSource = !this.removeSource; } })
        Button(this.fitMode === 0 ? 'Fit：Cover' : (this.fitMode === 1 ? 'Fit：Contain' : 'Fit：左上Cover'))
          .fontSize(11).height(30).layoutWeight(1)
          .id('spike_renderfit_toggle').onClick((): void => { if (!this.busy) { this.fitMode = (this.fitMode + 1) % 3; } })
      }.width('100%')
    }.width('100%')
  }

  @Builder
  ListContent() {
    Column({ space: 12 }) {
      Text('官方共享元素 · 双 Destination').fontSize(17).fontWeight(FontWeight.Medium)
        .id('spike_list_title')
      this.Controls()
      if (this.loading) {
        Text('正在准备同一份封面像素…').fontSize(12).id('spike_image_loading')
      } else if (this.loadError) {
        Button('重试加载封面').fontSize(12).id('spike_image_retry').onClick((): void => { this.loadCover(); })
      } else {
        Text('点卡片观察连续放大；返回观察原位缩回').fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      Grid() {
        ForEach(this.items, (item: HeroItem) => {
          GridItem() {
            Column({ space: 6 }) {
              Stack() {
                if (!(this.removeSource && this.selected === item.id)) {
                  this.SharedCover(item, false)
                } else {
                  Column().width('100%').height('100%').backgroundColor($r('app.color.btn_soft_bg'))
                    .borderRadius(12).id('spike_placeholder_' + item.id)
                }
              }
              .width('100%').aspectRatio(item.ratio)
              .id('spike_card_' + item.id)
              .onClick((): void => { this.openItem(item); })
              Text(item.title).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
            }.width('100%')
          }
        }, (item: HeroItem) => item.id)
      }
      .columnsTemplate('1fr 1fr').columnsGap(12).rowsGap(14)
      .layoutWeight(1).id('spike_list_grid')
    }
    .width('100%').height('100%')
    .padding({ left: 16, right: 16, top: this.statusBarH + 12, bottom: this.navBarH + 12 })
    .backgroundColor($r('app.color.bg_page')).id('spike_list_root')
  }

  @Builder
  DetailContent(item: HeroItem) {
    Column({ space: 16 }) {
      Row() {
        Button('返回').fontSize(13).height(34).id('spike_back')
          .onClick((): void => { this.closeDetail(); })
        Blank()
        Text(this.slow ? '1500ms' : '300ms').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.width('100%').padding({ left: 16, right: 16 })
      Column() { this.SharedCover(item, true) }
        .width('100%').aspectRatio(16 / 9).id('spike_detail_frame')
      Text('同一 PixelMap · ' + item.id.toUpperCase())
        .fontSize(18).fontWeight(FontWeight.Medium).id('spike_detail_title')
      Text((this.imageOnly ? '图片共享' : '裁剪容器共享') + ' / ' +
        (this.removeSource ? '源图 if 出树，卡位保留' : '源树保留') + ' / renderFit=' + this.fitMode.toString())
        .fontSize(12).fontColor($r('app.color.text_secondary')).padding({ left: 16, right: 16 })
      Text('观察起步、圆角、长宽比例与返回末帧；本页不创建播放器。')
        .fontSize(13).fontColor($r('app.color.text_secondary')).padding({ left: 16, right: 16 })
      Blank()
    }
    .width('100%').height('100%')
    .padding({ top: this.statusBarH + 8, bottom: this.navBarH + 12 })
    .backgroundColor($r('app.color.bg_page')).id('spike_detail_root')
  }

  @Builder
  Destination(name: string, param: object) {
    if (name === 'spikeList') {
      NavDestination() { this.ListContent() }
        .hideTitleBar(true).systemTransition(NavigationSystemTransitionType.NONE)
        .onBackPressed((): boolean => false)
    } else {
      NavDestination() { this.DetailContent(this.itemOf(param)) }
        .hideTitleBar(true).systemTransition(NavigationSystemTransitionType.NONE)
        .onBackPressed((): boolean => { this.closeDetail(); return true; })
    }
  }

  build() {
    Navigation(this.stack) {}
      .navDestination(this.Destination)
      .mode(NavigationMode.Stack).hideNavBar(true).hideTitleBar(true)
      .width('100%').height('100%')
      .backgroundColor($r('app.color.bg_page')).id('spike_navigation')
      .onAppear((): void => { this.mountRoot(); })
  }
}
