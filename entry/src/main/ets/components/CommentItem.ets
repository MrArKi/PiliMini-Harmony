/**
 * 评论条目组件（spec-05，Nara基准＋用户选定的只读点赞方案A）
 *  卡片 padding LTRB(12,14,8,5)｜头像 34（间距 12）｜名字 13sp + UP/TOP 徽章
 *  名字13/时间11头部后10｜正文14sp行高24.5｜点赞移至头部右侧居中
 *  评论图片网格（R9）｜子回复浅灰容器radius6，外top5/bottom12（R1/R2）
 *  「共N条回复」→ 楼中楼面板（R3）｜只读点赞icon16+数字11，无独立操作行
 */
import { AsyncImage } from './AsyncImage';
import { openMember, openMention } from '../common/member_route';
import { RichKind, RichSegment, RichText } from '../common/rich_text';
import { common } from '@kit.AbilityKit';
import { GalleryThumbnail, nextGalleryId } from './GalleryThumbnail';
import { thumbUrl } from '../infra/image/bili_image';
import { formatPlayCount } from './VideoCard';
import { CommentItem, CommentPic } from '../service/video_service';
import { CommentEmote } from '../model/emote';
import { naraDate } from '../common/nara_date';
import { InlineRichSpans } from './InlineRichText';

/** 网络返回的正文/表情作为快照，只缓存当前可见评论的解析结果。 */
class CommentTextCache {
  message: string = '';
  emotes: CommentEmote[] = [];
  segments: RichSegment[] = [];
}

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
  private messageCacheRpid: number = -1;
  private messageCache: CommentTextCache = new CommentTextCache();
  private previewCache: Map<number, CommentTextCache> = new Map<number, CommentTextCache>();
  private previewInlineHandled: boolean = false;
  private previewTapTimer: number = -1;
  private disposed: boolean = false;
  private emoteLoadedReported: boolean = false;
  private emoteFailedReported: boolean = false;

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.previewTapTimer >= 0) { clearTimeout(this.previewTapTimer); this.previewTapTimer = -1; }
  }

  aboutToAppear(): void { this.disposed = false; }

  /** Text 的点击不冒泡；父级并行 Tap 兜住文字之外的空白，链接/昵称仍单独处理。 */
  private openPreview(sub: CommentItem): void {
    if (this.previewTapTimer >= 0) { clearTimeout(this.previewTapTimer); }
    this.previewTapTimer = setTimeout((): void => {
      this.previewTapTimer = -1;
      const handled: boolean = this.previewInlineHandled;
      this.previewInlineHandled = false;
      if (!this.disposed && !handled) { this.onOpenSub(this.item, sub.rpid); }
    }, 0);
  }

  /** 只记录一次成功/失败，不含表情URL、正文或账号，便于最终包真机定位。 */
  private reportEmoteLoad(success: boolean): void {
    if (success && !this.emoteLoadedReported) {
      this.emoteLoadedReported = true;
      console.info('[PiliMini-comment] imageLoaded=1');
    } else if (!success && !this.emoteFailedReported) {
      this.emoteFailedReported = true;
      console.warn('[PiliMini-comment] imageFailed=1');
    }
  }

  /** 含链接/@时才分层渲染，普通评论保持单Text，不额外增加节点。 */
  private messageSegments(): RichSegment[] {
    if (this.messageCacheRpid !== this.item.rpid || this.messageCache.message !== this.item.message ||
      this.messageCache.emotes !== this.item.emotes) {
      if (this.messageCacheRpid !== this.item.rpid) { this.previewCache.clear(); }
      this.messageCacheRpid = this.item.rpid;
      this.messageCache.message = this.item.message;
      this.messageCache.emotes = this.item.emotes;
      const rich: boolean = RichText.isRich(this.item.message) || this.item.emotes.length > 0;
      this.messageCache.segments = rich ? RichText.parse(this.item.message, this.item.emotes) : [];
      if (this.item.emotes.length > 0 || this.item.message.indexOf('[') >= 0) {
        const images: number = this.messageCache.segments.filter((segment: RichSegment): boolean => segment.kind === RichKind.Emote).length;
        console.info('[PiliMini-comment] mapped=' + this.item.emotes.length.toString() + ' imageSegments=' + images.toString());
      }
    }
    return this.messageCache.segments;
  }

  private tapSegment(segment: RichSegment, scope: CommentItem): void {
    if (segment.kind === RichKind.Link) {
      RichText.openUrl(getContext(this) as common.UIAbilityContext, segment.target);
    } else if (segment.kind === RichKind.Mention) {
      const candidates: CommentItem[] = [this.item];
      for (let i: number = 0; i < this.item.replies.length; i++) { candidates.push(this.item.replies[i]); }
      if (candidates.indexOf(scope) < 0) { candidates.push(scope); }
      openMention(segment.target, candidates);
    }
  }

  private hasSubFooter(): boolean { return this.item.expanded || this.item.rcount > this.item.replies.length; }

  /** 预览只在正文/表情快照变化时解析；空文本返回单段，避免空Text。 */
  private subSegments(sub: CommentItem): RichSegment[] {
    let cached: CommentTextCache | undefined = this.previewCache.get(sub.rpid);
    if (cached === undefined || cached.message !== sub.message || cached.emotes !== sub.emotes) {
      cached = new CommentTextCache();
      cached.message = sub.message;
      cached.emotes = sub.emotes;
      cached.segments = sub.message.length > 0 ? RichText.parse(sub.message, sub.emotes)
        : [new RichSegment(RichKind.Plain, ' ', '')];
      this.previewCache.set(sub.rpid, cached);
    }
    return cached.segments;
  }
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
    Column() {
    Text() {
      if (this.upMid > 0 && sub.mid === this.upMid) {
        Span('UP ')
          .fontColor($r('app.color.brand_pink'))
          .fontSize(12)
      }
      Span(sub.uname + '：')
        .fontColor($r('app.color.brand_pink'))
        .fontSize(14)
        .onClick((): void => { this.previewInlineHandled = true; openMember(sub.mid); })
      // 不在Text上绑onClick；外层并行Tap覆盖整行，昵称/链接保持独立。
      InlineRichSpans(this.subSegments(sub), 14, false, (segment: RichSegment): void => {
        this.previewInlineHandled = true; this.tapSegment(segment, sub);
      }, (success: boolean): void => { this.reportEmoteLoad(success); })
    }
    .lineHeight(22.4)
    .maxLines(2)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .width('100%')
    }
    .width('100%')
    .padding({
      left: 8,
      right: 8,
      top: this.item.replies.length === 1 && !this.hasSubFooter() ? 5 : (first ? 8 : 4),
      bottom: this.item.replies.length === 1 && !this.hasSubFooter() ? 5 : (last ? 8 : 4)
    })
    .id('comment_preview_' + sub.rpid.toString())
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) { this.previewInlineHandled = false; }
    })
    .parallelGesture(TapGesture().onAction((): void => { this.openPreview(sub); }))
  }

  build() {
    Column() {
      // 方案A：头像＋可收缩的名字/时间列＋只读点赞，后两者与头像垂直居中。
      Row({ space: 12 }) {
        Column() {
          AsyncImage({ src: thumbUrl(this.item.avatar, 96, 96), w: 96, h: 96 })
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))
        .id('comment_avatar_' + this.item.rpid.toString())
        .onClick(() => { openMember(this.item.mid); })

        Column() {
          // 名字行（13sp + UP/TOP 徽章）
          Row({ space: 6 }) {
            Text(this.item.uname)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .flexShrink(1)
            if (this.upMid > 0 && this.item.mid === this.upMid) {
              Text('UP')
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.brand_pink'))
                .borderRadius(3)
                .padding({ left: 3, right: 3, top: 1, bottom: 1 })
                .flexShrink(0)
            }
            if (this.item.isUpTop) {
              Text('TOP')
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor('#FF6699')
                .borderRadius(3)
                .padding({ left: 3, right: 3, top: 1, bottom: 1 })
                .flexShrink(0)
            }
          }
          .width('100%')
          Text(naraDate(this.item.ctime))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .id('comment_author_' + this.item.rpid.toString())
        .parallelGesture(TapGesture().onAction((): void => { openMember(this.item.mid); }))

        Row({ space: 4 }) {
          Image($r('app.media.icon_thumbup'))
            .width(16).height(16).fillColor($r('app.color.text_secondary'))
            .flexShrink(0)
          Text(formatPlayCount(this.item.like))
            .fontSize(11).fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .flexShrink(0)
        }
        .flexShrink(0)
        .margin({ right: 5 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 正文与图片保留分段间距，正文后直接接灰底回复，不再放空操作行。
      Column() {
        if (this.item.message.length > 0) {
          if (this.messageSegments().length > 0) {
            Text() {
              InlineRichSpans(this.messageSegments(), 14, false, (segment: RichSegment): void => {
                this.tapSegment(segment, this.item);
              }, (success: boolean): void => { this.reportEmoteLoad(success); })
            }
            .fontSize(14)
            .lineHeight(24.5)
            .width('100%')
          } else {
            Text(this.item.message)
              .fontSize(14)
              .lineHeight(24.5)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
          }
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
      } else {
        Column().height(8)
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
