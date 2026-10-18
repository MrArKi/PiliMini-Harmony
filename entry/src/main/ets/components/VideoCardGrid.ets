/**
 * 双列视频卡片（首页 V2，对照 PiliNara VideoCard 实拍）
 *  封面 16:10 圆角 6 + 右下时长角标
 *  标题 14sp/行高 20/maxLines 2
 *  播放/弹幕行：icon 13 + 12sp 灰
 *  UP 名 12sp 灰（单行省略）+ ⋮ 更多（bindSheet：稍后再看 / 复制链接）
 * 规格来源：docs/specs/spec-04-首页与搜索.md §8、docs/ui/首页.html
 */
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AsyncImage } from './AsyncImage';
import { VideoItem } from '../model/video_item';
import { formatPlayCount, formatDuration } from './VideoCard';
import { FavService } from '../service/fav_service';
import { AuthService } from '../service/auth_service';

@Component
export struct VideoCardGrid {
  @Prop model: VideoItem;
  @State moreShown: boolean = false;
  private destroyed: boolean = false;

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  private aid(): number {
    const v: number | undefined = this.model.aid;
    return v !== undefined && v > 0 ? v : 0;
  }

  private async addLater(): Promise<void> {
    const aid: number = this.aid();
    if (aid <= 0) {
      promptAction.showToast({ message: '该视频暂不支持稍后再看' });
      return;
    }
    const logged: boolean = await AuthService.isLogin();
    if (this.destroyed) {
      return;
    }
    if (!logged) {
      promptAction.showToast({ message: '请先登录' });
      return;
    }
    try {
      await FavService.laterAdd(aid);
      if (!this.destroyed) {
        promptAction.showToast({ message: '已添加到稍后再看' });
      }
    } catch (error) {
      if (!this.destroyed) {
        promptAction.showToast({ message: '添加失败，请重试' });
      }
    }
  }

  private async copyLink(): Promise<void> {
    if (this.model.bvid.length === 0) {
      return;
    }
    const url: string = 'https://www.bilibili.com/video/' + this.model.bvid;
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    await pasteboard.getSystemPasteboard().setData(data);
    if (!this.destroyed) {
      promptAction.showToast({ message: '链接已复制' });
    }
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
  MorePanel() {
    Column() {
      Text('稍后再看')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          this.moreShown = false;
          this.addLater();
        })
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      Text('复制链接')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          this.moreShown = false;
          this.copyLink();
        })
    }
    .width('100%')
    .padding({ bottom: 12 })
  }

  build() {
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
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })

      Row({ space: 8 }) {
        this.Stat($r('app.media.icon_play'), formatPlayCount(this.model.playCount))
        this.Stat($r('app.media.icon_danmaku'), formatPlayCount(this.model.danmaku))
      }
      .width('100%')
      .margin({ top: 6 })

      Row() {
        Text(this.model.upName)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Image($r('app.media.icon_more'))
            .width(22).height(22)
          .fillColor($r('app.color.text_secondary'))
          .padding({ left: 6, right: 2 })
          .onClick(() => {
            this.moreShown = true;
          })
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .bindSheet($$this.moreShown, this.MorePanel(), {
      height: 156,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.card_bg')
    })
    .onClick(() => {
      if (this.model.bvid.length > 0) {
        const params: Record<string, string> = { 'bvid': this.model.bvid, 'title': this.model.title };
        router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
      }
    })
  }
}
