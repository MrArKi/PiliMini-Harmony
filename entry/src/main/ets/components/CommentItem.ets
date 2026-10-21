/**
 * 评论条目组件（spec-05 返工 R1~R9，1:1 对齐 PiliNara reply_item_grpc.dart）
 *  卡片 padding LTRB(12,14,8,5)｜头像 34（间距 12）｜名字 13sp + UP/TOP 徽章
 *  名字13/时间11头部后10｜正文14sp行高24.5｜操作前4（带图额外4）
 *  评论图片网格（R9）｜子回复浅灰容器radius6，外top5/bottom12（R1/R2）
 *  「共N条回复」→ 楼中楼面板（R3）｜操作行高 32，右侧点赞 icon16+数字（R4）
 */
import { AsyncImage } from './AsyncImage';
import { openMember } from '../common/member_route';
import { GalleryThumbnail, nextGalleryId } from './GalleryThumbnail';
import { thumbUrl } from '../infra/image/bili_image';
import { formatPlayCount } from './VideoCard';
import { CommentItem, CommentPic } from '../service/video_service';
import { naraDate } from '../common/nara_date';

@Component
export struct CommentItemView {
  @ObjectLink item: CommentItem;
  @Prop upMid: number = 0;
  /** 子回复预览传目标ID；「共N条回复」传0，只打开楼中楼。 */
  onOpenSub: (item: CommentItem, targetRpid: number) => void = () => {
  };
  /** 楼中楼页面中的「主评论」：不再显示「共N条回复」入口 */
  @Prop hideSubEntry: boolean = false;
  /** 「展开更多回复」/「加载失败重试」 */
  onSubMore: (item: CommentItem) => void = () => {
  };

  private galleryId: string = nextGalleryId();
  private hasSubFooter(): boolean { return this.item.expanded || this.item.rcount > this.item.replies.length; }
  private pictureUrls(pics: CommentPic[]): string[] { return pics.map((p: CommentPic) => p.url); }
  private pictureThumbs(pics: CommentPic[]): string[] {
    return pics.map((p: CommentPic) => thumbUrl(p.url, pics.length === 1 ? 480 : 320, 320));
  }

  // ===== 评论图片网格（R9：1 大图 / 2-3 列 / 4→2×2 / 5-9 九宫格） =====
  private perRowOf(n: number): number {
    if (n === 2) {
      return 2;
    }
    if (n === 4) {
      return 2;
    }
    return 3;
  }

  private ratioOf(p: CommentPic): number {
    let r: number = (p.width > 0 && p.height > 0) ? p.width / p.height : 1.6;
    if (r > 1.8) {
      r = 1.8;
    }
    if (r < 0.75) {
      r = 0.75;
    }
    return r;
  }

  private rowStarts(n: number, perRow: number): number[] {
    const out: number[] = [];
    let i: number = 0;
    while (i < n) {
      out.push(i);
      i += perRow;
    }
    return out;
  }

  private emptyCount(n: number, start: number, perRow: number): number[] {
    const used: number = Math.min(perRow, n - start);
    const empties: number[] = [];
    for (let i = 0; i < perRow - used; i++) {
      empties.push(i);
    }
    return empties;
  }

  @Builder
  PicGrid(pics: CommentPic[]) {
    Column({ space: 4 }) {
      if (pics.length === 1) {
        Column() {
          GalleryThumbnail({ urls: this.pictureUrls(pics), thumbs: this.pictureThumbs(pics), index: 0,
            groupId: this.galleryId, w: 480, h: 320 })
        }
        .width('72%')
        .aspectRatio(this.ratioOf(pics[0]))
        .borderRadius(4)
        .clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))
        .onClick(() => { openMember(this.item.mid); })
      } else {
        ForEach(this.rowStarts(pics.length, this.perRowOf(pics.length)), (rowStart: number) => {
          Row({ space: 4 }) {
            ForEach(pics.slice(rowStart, rowStart + this.perRowOf(pics.length)), (p: CommentPic, idx: number) => {
              Column() {
                GalleryThumbnail({ urls: this.pictureUrls(pics), thumbs: this.pictureThumbs(pics), index: rowStart + idx,
                  groupId: this.galleryId, w: 320, h: 320 })
              }
              .layoutWeight(1)
              .aspectRatio(1)
              .borderRadius(4)
              .clip(true)
              .backgroundColor($r('app.color.btn_soft_bg'))
            }, (p: CommentPic) => p.url)
            ForEach(this.emptyCount(pics.length, rowStart, this.perRowOf(pics.length)), (e: number) => {
              Column()
                .layoutWeight(1)
                .aspectRatio(1)
            }, (e: number) => 'ce' + rowStart.toString() + '_' + e.toString())
          }
          .width('100%')
        }, (rowStart: number) => 'cr' + rowStart.toString())
      }
    }
    .width(pics.length === 4 ? '66%' : '100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 子回复文本（14sp / 行高 1.6 / maxLines 2，名字 primary） =====
  @Builder
  SubLine(sub: CommentItem, first: boolean, last: boolean) {
    Text() {
      if (this.upMid > 0 && sub.mid === this.upMid) {
        Span('UP ')
          .fontColor($r('app.color.brand_pink'))
          .fontSize(12)
      }
      Span(sub.uname + '：')
        .fontColor($r('app.color.brand_pink'))
        .fontSize(14)
      Span(sub.message)
        .fontColor($r('app.color.text_primary'))
        .fontSize(14)
    }
    .lineHeight(22.4)
    .maxLines(2)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .width('100%')
    .padding({
      left: 8,
      right: 8,
      top: this.item.replies.length === 1 && !this.hasSubFooter() ? 5 : (first ? 8 : 4),
      bottom: this.item.replies.length === 1 && !this.hasSubFooter() ? 5 : (last ? 8 : 4)
    })
    .id('comment_preview_' + sub.rpid.toString())
    .onClick(() => { this.onOpenSub(this.item, sub.rpid); })
  }

  build() {
    Column() {
      // Nara头部是独立的34头像＋名字/时间列；不能把头像与整段正文并排。
      Row({ space: 12 }) {
        Column() {
          AsyncImage({ src: thumbUrl(this.item.avatar, 96, 96), w: 96, h: 96 })
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))

        Column() {
          // 名字行（13sp + UP/TOP 徽章）
          Row({ space: 6 }) {
            Text(this.item.uname)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '60%' })
              .onClick(() => { openMember(this.item.mid); })
            if (this.upMid > 0 && this.item.mid === this.upMid) {
              Text('UP')
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.brand_pink'))
                .borderRadius(3)
                .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            }
            if (this.item.isUpTop) {
              Text('TOP')
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor('#FF6699')
                .borderRadius(3)
                .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            }
          }
          .width('100%')
          Text(naraDate(this.item.ctime))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 正文/图片只应用Nara规定的段间距，不用Column(space:10)扩散到操作行。
      Column() {
        if (this.item.message.length > 0) {
          Text(this.item.message)
            .fontSize(14)
            .lineHeight(24.5)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
        }
        if (this.item.pics.length > 0) {
          this.PicGrid(this.item.pics)
          Column().height(4)
        }
      }
      .width('100%')
      .padding({ left: 45, right: 6 })
      .margin({ top: 10 })
      .alignItems(HorizontalAlign.Start)

      Row() {
        Blank()
        Row({ space: 4 }) {
          Image($r('app.media.icon_thumbup'))
            .width(16).height(16).fillColor($r('app.color.text_secondary'))
          Text(formatPlayCount(this.item.like))
            .fontSize(11).fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%').height(32).padding({ right: 5 }).margin({ top: 4 })

      // ===== 子回复容器（R1/R2）=====
      // hideSubEntry：楼中楼页面里的「主评论」不再显示「共N条回复」入口（用户指正 2026-10-12）
      if (!this.hideSubEntry && (this.item.replies.length > 0 || this.item.rcount > 0)) {
        Column() {
          if (this.item.replies.length > 0) {
            ForEach(this.item.replies, (sub: CommentItem, si: number) => {
              this.SubLine(sub, si === 0, si === this.item.replies.length - 1
                && !this.hasSubFooter())
            }, (sub: CommentItem) => 'sub_' + sub.rpid.toString())
          }
          if (!this.item.expanded && this.item.rcount > this.item.replies.length) {
            Text('共 ' + this.item.rcount.toString() + ' 条回复，点击查看')
              .fontSize(12)
              .fontColor($r('app.color.brand_pink'))
              .width('100%')
              .padding({ left: 8, right: 8, top: this.item.replies.length === 0 ? 6 : 5,
                bottom: this.item.replies.length === 0 ? 6 : 8 })
              .onClick(() => {
                this.onOpenSub(this.item, 0);
              })
          } else if (this.item.expanded) {
            Text(this.subFooterText())
              .fontSize(12)
              .fontColor($r('app.color.brand_pink'))
              .width('100%')
              .padding({ left: 8, right: 8, top: this.item.replies.length === 0 ? 6 : 5,
                bottom: this.item.replies.length === 0 ? 6 : 8 })
              .onClick(() => {
                if (this.item.subErr || this.item.subHasMore) {
                  this.onSubMore(this.item);
                } else {
                  this.onOpenSub(this.item, 0);
                }
              })
          }
        }
        .width('calc(100% - 46vp)')
        .backgroundColor($r('app.color.comment_sub_bg'))
        .borderRadius(6)
        .clip(true)
        .id('comment_replies_' + this.item.rpid.toString())
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 42, right: 4, top: 5, bottom: 12 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 14, bottom: 5 })
    .alignItems(HorizontalAlign.Start)
    // 主评论surface与回复灰底必须分开；楼中楼保持透明，不能盖住父行的目标高亮。
    .backgroundColor(this.hideSubEntry ? Color.Transparent
      : (this.item.isUpTop ? $r('app.color.comment_top_bg') : $r('app.color.card_bg')))
  }

  /** 展开态底部文案 */
  private subFooterText(): string {
    if (this.item.subLoading) {
      return '加载中…';
    }
    if (this.item.subErr) {
      return '加载失败，点击重试';
    }
    if (this.item.subHasMore) {
      return '展开更多回复';
    }
    return '收起';
  }
}

/** 评论骨架屏（R6：×5，灰块行 = 圆头像 + 2~3 行条） */
@Component
export struct CommentSkeleton {
  @Prop variant: number = 0;

  build() {
    Row({ space: 12 }) {
      Column()
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor($r('app.color.btn_soft_bg'))

      Column({ space: 9 }) {
        Column()
          .width(this.variant % 2 === 0 ? '36%' : '28%')
          .height(12)
          .borderRadius(6)
          .backgroundColor($r('app.color.btn_soft_bg'))
        Column()
          .width('92%')
          .height(12)
          .borderRadius(6)
          .backgroundColor($r('app.color.btn_soft_bg'))
        if (this.variant % 3 !== 0) {
          Column()
            .width('62%')
            .height(12)
            .borderRadius(6)
            .backgroundColor($r('app.color.btn_soft_bg'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 14, bottom: 10 })
    .alignItems(VerticalAlign.Top)
  }
}
