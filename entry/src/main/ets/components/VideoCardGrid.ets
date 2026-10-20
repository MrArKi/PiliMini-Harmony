/**
 * 双列视频卡片（首页 V2，对照 PiliNara VideoCard 实拍）
 *  封面 16:10 圆角 6 + 右下时长角标
 *  标题 14sp/行高 20/maxLines 2
 *  播放/弹幕行：icon 13 + 12sp 灰
 *  UP 名 12sp 灰（单行省略）+ 卡片锚定菜单
 * 规格来源：docs/specs/spec-04-首页与搜索.md §8、docs/ui/首页.html
 */
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AsyncImage } from './AsyncImage';
import { VideoItem } from '../model/video_item';
import { formatPlayCount, formatDuration } from './VideoCard';
import { FavService } from '../service/fav_service';
import { AuthService } from '../service/auth_service';
import { openMember } from '../common/member_route';

@Component
export struct VideoCardGrid {
  @Prop model: VideoItem;
  @State moreShown: boolean = false;
  @State addingLater: boolean = false;
  private destroyed: boolean = false;

  aboutToDisappear(): void {
    this.destroyed = true;
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

  private openVideo(): void {
    if (this.model.bvid.length === 0) { return; }
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
      if (this.model.bvid.length > 0) {
        MenuItem(this.MenuRow($r('app.media.icon_link'), '复制链接'))
          .onClick(() => { this.moreShown = false; this.copyVideo(true); })
        MenuItem(this.MenuRow($r('app.media.icon_copy'), '复制BV号'))
          .onClick(() => { this.moreShown = false; this.copyVideo(false); })
      }
    }.width(192)
  }

  build() {
    Column() {
      Column() {
      // 封面 + 右下时长角标
      Stack({ alignContent: Alignment.BottomEnd }) {
        AsyncImage({ src: this.model.cover, w: 320, h: 200 })
          .width('100%')
          .aspectRatio(1.6)
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
      .borderRadius(6)
      .clip(true)
      .backgroundColor($r('app.color.btn_soft_bg'))

      Text(this.model.title)
        .fontSize(14)
        .lineHeight(20)
        .letterSpacing(0.3)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .height(40)
        .align(Alignment.TopStart)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })

      Row({ space: 8 }) {
        this.Stat($r('app.media.icon_play'), formatPlayCount(this.model.playCount))
        this.Stat($r('app.media.icon_danmaku'), formatPlayCount(this.model.danmaku))
      }
      .width('100%')
      .margin({ top: 6 })
      }.width('100%').alignItems(HorizontalAlign.Start).onClick(() => { this.openVideo(); })

      Row() {
        Text(this.model.upName)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .onClick(() => { this.openVideo(); })
        Row() {
          Image($r('app.media.icon_more')).width(17).height(17)
            .fillColor($r('app.color.text_secondary'))
        }
          .width(44).height(44).justifyContent(FlexAlign.End).padding({ right: 2 })
          .id('home_more_' + this.model.bvid).accessibilityText('视频更多操作')
          .onClick(() => {
            this.moreShown = !this.moreShown;
          })
          .bindMenu(this.moreShown, this.MoreMenu(), { placement: Placement.TopRight,
            enableArrow: false, onDisappear: () => { this.moreShown = false; } })
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
