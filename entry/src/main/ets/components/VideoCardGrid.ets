import { image } from '@kit.ImageKit';
/**
 * 首页视频卡片（推荐双列竖卡 / 热门单列横卡，对照 PiliNara）
 *  封面 16:10（推荐整卡圆角12 / 热门封面圆角10）+ 右下时长角标
 *  推荐信息区90vp，标题14sp/行高19.32/maxLines 2；热门行高20
 *  播放/弹幕行：icon 13 + 12sp 灰
 *  UP 名 12sp 灰（单行省略）+ 卡片锚定菜单
 * 规格来源：docs/specs/spec-04-首页与搜索.md、docs/ui/首页推荐与热门.html
 */
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AsyncImage } from './AsyncImage';
import { VideoItem } from '../model/video_item';
import { formatPlayCount, formatDuration } from './VideoCard';
import { FavService } from '../service/fav_service';
import { AuthService } from '../service/auth_service';
import { openMember } from '../common/member_route';
import { naraDate } from '../common/nara_date';
import { HeroRect, HeroRoute, HeroSourceHandle, VideoNavParam } from '../common/hero_route';

let videoCardSerial: number = 0;
function nextVideoCardId(): string { return 'vcard_' + (++videoCardSerial).toString(); }

@Component
export struct VideoCardGrid {
  @Prop model: VideoItem;
  @Prop horizontal: boolean = false;
  @State moreShown: boolean = false;
  @State addingLater: boolean = false;
  onFeedback: (mode: string, item: VideoItem) => void = () => {};
  private destroyed: boolean = false;
  private sourceId: string = nextVideoCardId();
  private displayedCover: image.PixelMap | undefined = undefined;
  @State heroHidden: boolean = false;
  @State returnFrame: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.destroyed = false;
    const handle: HeroSourceHandle = new HeroSourceHandle();
    handle.setFrame = (frame: image.PixelMap | undefined): void => { this.returnFrame = frame; };
    handle.setHidden = (hidden: boolean): void => { this.heroHidden = hidden; };
    handle.rect = (): HeroRect => this.cardRect();
    HeroRoute.registerSource(this.sourceId, handle);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    HeroRoute.unregisterSource(this.sourceId);
    this.returnFrame = undefined;
    this.displayedCover = undefined;
    HeroRoute.updateRect(this.sourceId, new HeroRect());
  }

  private aid(): number {
    const v: number | undefined = this.model.aid;
    return v !== undefined && v > 0 ? v : 0;
  }

  private async addLater(): Promise<void> {
    if (this.addingLater || this.destroyed) { return; }
    const aid: number = this.aid();
    if (aid <= 0) {
      promptAction.showToast({ message: '该视频暂不支持稍后再看' });
      return;
    }
    this.addingLater = true;
    try {
      const logged: boolean = await AuthService.isLogin();
      if (this.destroyed) { return; }
      if (!logged) { promptAction.showToast({ message: '请先登录' }); return; }
      await FavService.laterAdd(aid);
      if (!this.destroyed) {
        promptAction.showToast({ message: '已添加到稍后再看' });
      }
    } catch (error) {
      if (!this.destroyed) {
        promptAction.showToast({ message: '添加失败，请重试' });
      }
    } finally {
      if (!this.destroyed) { this.addingLater = false; }
    }
  }

  private async copyVideo(link: boolean): Promise<void> {
    if (this.model.bvid.length === 0) {
      return;
    }
    const text: string = link ? 'https://www.bilibili.com/video/' + this.model.bvid : this.model.bvid;
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      if (!this.destroyed) { promptAction.showToast({ message: link ? '链接已复制' : 'BV号已复制' }); }
    } catch (_) {
      if (!this.destroyed) { promptAction.showToast({ message: '复制失败，请重试' }); }
    }
  }

  private ownerMid(): number { return this.model.upMid !== undefined ? this.model.upMid : 0; }

  private ownerLine(): string {
    const date: string = naraDate(this.model.pubdate);
    return (date.length > 0 ? date + '  ' : '') + this.model.upName;
  }

  /** 官方 ComponentInfo 的 size/windowOffset 均为 px；点击和布局更新共用整卡落点。 */
  private cardRect(): HeroRect {
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(this.sourceId + '_cover');
      return new HeroRect(px2vp(info.windowOffset.x), px2vp(info.windowOffset.y),
        px2vp(info.size.width), px2vp(info.size.height));
    } catch (_) {
      return new HeroRect();
    }
  }

  private openVideo(): void {
    if (this.model.bvid.length === 0) { return; }
    const cid: number = this.model.cid !== undefined ? this.model.cid : 0;
    const rect: HeroRect = this.cardRect();
    HeroRoute.updateRect(this.sourceId, rect);
    if (HeroRoute.push(new VideoNavParam(this.model.bvid, cid, this.model.title, this.model.cover, rect, this.sourceId, this.returnFrame || this.displayedCover))) { return; }
    const params: Record<string, string> = { 'bvid': this.model.bvid, 'title': this.model.title };
    router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
  }

  @Builder
  Stat(icon: Resource, value: string) {
    Row({ space: 2 }) {
      Image(icon)
        .width(13)
        .height(13)
        .fillColor($r('app.color.text_secondary'))
        .opacity(0.8)
      Text(value)
        .fontSize(12)
        .lineHeight(17.14)
        .fontColor($r('app.color.text_secondary'))
    }
  }

  @Builder
  MenuRow(icon: Resource, label: string) {
    Row({ space: 8 }) {
      Image(icon).width(16).height(16).fillColor($r('app.color.text_secondary'))
      Text(label).fontSize(13).fontColor($r('app.color.text_primary')).maxLines(1)
    }
    .width('100%').height(45).padding({ left: 8, right: 8 })
  }

  @Builder
  MoreMenu() {
    Menu() {
      if (this.aid() > 0) {
        MenuItem(this.MenuRow($r('app.media.icon_clock'), this.addingLater ? '正在添加…' : '稍后再看'))
          .enabled(!this.addingLater)
          .onClick(() => { this.moreShown = false; this.addLater(); })
      }
      if (this.ownerMid() > 0) {
        MenuItem(this.MenuRow($r('app.media.icon_person'), '访问UP主'))
          .onClick(() => { this.moreShown = false; openMember(this.ownerMid()); })
      }
      MenuItem(this.MenuRow($r('app.media.icon_feed_block'), '本地屏蔽'))
        .onClick(() => { this.moreShown = false; this.onFeedback('block', this.model); })
      if (this.model.bvid.length > 0) {
        MenuItem(this.MenuRow($r('app.media.icon_feed_dislike'), '隐藏此视频'))
          .onClick(() => { this.moreShown = false; this.onFeedback('dislike', this.model); })
      }
      if (this.ownerMid() > 0) {
        MenuItem(this.MenuRow($r('app.media.icon_feed_black'), '拉黑：' + this.model.upName))
          .onClick(() => { this.moreShown = false; this.onFeedback('black', this.model); })
      }
      MenuItem(this.MenuRow($r('app.media.icon_settings'), '屏蔽管理'))
        .onClick(() => { this.moreShown = false; this.onFeedback('manage', this.model); })
      if (this.model.bvid.length > 0) {
        MenuItem(this.MenuRow($r('app.media.icon_link'), '复制链接'))
          .onClick(() => { this.moreShown = false; this.copyVideo(true); })
        MenuItem(this.MenuRow($r('app.media.icon_copy'), '复制BV号'))
          .onClick(() => { this.moreShown = false; this.copyVideo(false); })
      }
    }.width(192)
  }

  @Builder
  Cover() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 原封面始终挂载，回程帧只作临时叠层；转场结束无需重新加载原图。
      AsyncImage({ src: this.model.cover, w: 320, h: 200,
        onDisplayed: (pixel: image.PixelMap): void => { this.displayedCover = pixel; } })
        .width('100%').height('100%')
      if (this.returnFrame !== undefined) {
        Image(this.returnFrame).width('100%').height('100%').objectFit(ImageFit.Cover)
          .syncLoad(true).autoResize(false)
      }
      if (this.model.duration > 0) {
        Text(formatDuration(this.model.duration))
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#80000000')
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 6, bottom: 6 })
      }
    }
    .width('100%')
    .aspectRatio(1.6)
    // 竖卡由卡片容器圆角裁剪（Nara：Card clipBehavior=hardEdge，封面自身不带圆角）
    .borderRadius(this.horizontal ? 10 : { topLeft: 12, topRight: 12, bottomLeft: 0, bottomRight: 0 })
    .clip(true)
    .opacity(this.heroHidden ? 0 : 1)
    .id(this.sourceId + '_cover')
    .backgroundColor($r('app.color.btn_soft_bg'))
  }

  @Builder
  MoreButton() {
    Row() {
      Image($r('app.media.icon_more')).width(17).height(17)
        .fillColor($r('app.color.text_secondary'))
    }
      .width(44).height(44).justifyContent(FlexAlign.End).padding({ right: 2 })
      .margin({ right: this.horizontal ? 12 : 0 })
      .offset({ y: this.horizontal ? 0 : 8 })
      .id('home_more_' + this.model.bvid).accessibilityText('视频更多操作')
      .onClick(() => {
        this.moreShown = !this.moreShown;
      })
      .bindMenu(this.moreShown, this.MoreMenu(), { placement: Placement.TopRight,
        enableArrow: false, onDisappear: () => { this.moreShown = false; } })
  }

  /** Nara VideoCardH：110vp行，160×100封面，菜单与内容为独立点击目标。 */
  @Builder
  HorizontalCard() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Row({ space: 10 }) {
        Column() { this.Cover() }
          .width(160).height(100)
          .onClick(() => { this.openVideo(); })

        Column() {
          Text(this.model.title)
            .fontSize(14).lineHeight(20).letterSpacing(0.3)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2).height(40).width('100%').align(Alignment.TopStart)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
          Column() {
            Text(this.ownerLine())
              .fontSize(12).lineHeight(12).height(12).fontColor($r('app.color.text_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Row({ space: 8 }) {
              this.Stat($r('app.media.icon_play'), formatPlayCount(this.model.playCount))
              this.Stat($r('app.media.icon_danmaku'), formatPlayCount(this.model.danmaku))
            }
            .margin({ top: 3 })
          }
          .width('100%').padding({ right: 44 }).alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1).height(100).alignItems(HorizontalAlign.Start)
        .onClick(() => { this.openVideo(); })
      }
      .width('100%').height(110)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })

      this.MoreButton()
    }
    .width('100%').height(110)
  }

  @Builder
  VerticalCard() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 卡片本体：与 Nara 首页竖卡一致 —— M3 Card，圆角 12、有独立卡面底色
      Column() {
        Column() {
          this.Cover()

          // Nara VideoCardV：信息区90vp，菜单独立浮层，不撑高18vp的UP行。
          Column() {
            Text(this.model.title)
              .fontSize(14)
              .lineHeight(19.32)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .layoutWeight(1)
              .align(Alignment.TopStart)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            Row({ space: 4 }) {
              this.Stat($r('app.media.icon_play'), formatPlayCount(this.model.playCount))
              this.Stat($r('app.media.icon_danmaku'), formatPlayCount(this.model.danmaku))
            }
            .width('100%').height(17.14)

            Text(this.model.upName)
              .fontSize(12)
              .lineHeight(18)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').height(18)
              .padding({ right: 28 })
          }
          .width('100%').height(90)
          .padding({ left: 6, right: 6, top: 5, bottom: 5 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(12)
        .clip(true)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(12)
      .shadow({ radius: 2, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 1 })
      .onClick(() => { this.openVideo(); })

      this.MoreButton()
    }
    .width('100%')
  }

  build() {
    Column() {
      if (this.horizontal) {
        this.HorizontalCard()
      } else {
        this.VerticalCard()
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    // 供一镜到底量取窗口矩形（spec-33）
    .id(this.sourceId)
    .onAreaChange((): void => {
      if (!this.destroyed && this.model.bvid.length > 0) {
        HeroRoute.updateRect(this.sourceId, this.cardRect());
      }
    })
  }
}
