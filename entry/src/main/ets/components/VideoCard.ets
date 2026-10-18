/**
 * 视频卡片（水平布局，1:1 对齐 PiliNara VideoCardH）
 *  卡片 padding h12/v5；封面 16:10（Nara Style.aspectRatio）圆角 6 + 右下时长角标
 *  右侧：标题 14sp 行高 20（maxLines 2）→ "MM-DD UP名" 12sp 灰 → [播放 icon13+12sp] [弹幕 icon13+12sp]
 */
import { router } from '@kit.ArkUI';
import { AsyncImage } from './AsyncImage';
import { VideoItem } from '../model/video_item';
import { naraDate } from '../common/nara_date';

export function formatPlayCount(n: number): string {
  if (n >= 100000000) {
    return (n / 100000000).toFixed(1) + '亿';
  }
  if (n >= 10000) {
    return (n / 10000).toFixed(1) + '万';
  }
  return n.toString();
}

function two(n: number): string {
  const s: string = n.toString();
  return s.length >= 2 ? s : '0' + s;
}

export function formatDuration(sec: number): string {
  const whole: number = Number.isFinite(sec) ? Math.max(0, Math.floor(sec)) : 0;
  const m: number = Math.floor(whole / 60);
  const s: number = whole % 60;
  return two(m) + ':' + two(s);
}

/** MM-DD（Nara DateFormatUtils.dateFormat） */
function fmtShortDate(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const d = new Date(ts * 1000);
  return two(d.getMonth() + 1) + '-' + two(d.getDate());
}

@Component
export struct VideoCard {
  @Prop model: VideoItem;
  @Prop spaceCard: boolean = false;

  /** StatWidget：icon 13 + 12sp 文本，spacing 2 */
  @Builder
  Stat(icon: Resource, value: number) {
    Row({ space: 2 }) {
      Image(icon)
        .width(13)
        .height(13)
        .fillColor($r('app.color.text_secondary'))
        .opacity(0.8)
      Text(formatPlayCount(value))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
  }

  build() {
    Row({ space: 10 }) {
      // 封面（16:10 + 右下时长角标）
      Stack({ alignContent: Alignment.BottomEnd }) {
        AsyncImage({ src: this.model.cover, w: 320, h: 200 })
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
      .width(160)
      .height(100)
      .borderRadius(6)
      .clip(true)
      .backgroundColor($r('app.color.btn_soft_bg'))

      // 内容区
      Column() {
        Text(this.model.title)
          .fontSize(14)
          .lineHeight(20)
          .letterSpacing(0.3)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Blank()

        Row({ space: 6 }) {
          if (this.model.pubdate > 0) {
            Text(this.spaceCard ? naraDate(this.model.pubdate) : fmtShortDate(this.model.pubdate))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          if (!this.spaceCard) {
            Text(this.model.upName)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          }
        }
        .width('100%')
        .margin({ bottom: 3 })

        Row({ space: 8 }) {
          this.Stat($r('app.media.icon_play'), this.model.playCount)
          this.Stat($r('app.media.icon_danmaku'), this.model.danmaku)
        }
      }
      .layoutWeight(1)
      .height(100)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
    .onClick(() => {
      if (this.model.bvid.length > 0) {
        const params: Record<string, string> = { 'bvid': this.model.bvid, 'title': this.model.title };
        router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
      }
    })
  }
}
