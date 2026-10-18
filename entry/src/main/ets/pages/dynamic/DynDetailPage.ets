/**
 * 动态详情页（2026-10-11 用户指示：图文动态点击进入详情，对齐 Nara 动态详情页）
 *  - 内容：作者行 / 完整正文 / 图片网格（Nara _calcGridInfo 规则）/ 转发块 / 行动栏（展示）
 *  - 图片点击放大（ImageViewer）
 *  - 2026-10-12 V2：分段条（转发/评论/赞，评论可用）+ 最热/最新排序 + 评论列表（含图）+ 楼中楼内联展开（type=17）
 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { openMember } from '../../common/member_route';
import { common } from '@kit.AbilityKit';
import { router, display, promptAction } from '@kit.ArkUI';
import { AsyncImage } from '../../components/AsyncImage';
import { GalleryThumbnail, nextGalleryId } from '../../components/GalleryThumbnail';
import { CommentItemView, CommentSkeleton } from '../../components/CommentItem';
import { SubReplyArgs } from '../../service/sub_reply_ctx';
import { BasicDataSource } from '../../common/list_data_source';
import { formatPlayCount } from '../../components/VideoCard';
import { DynamicService, DynItem, DynPic, DynParagraph, DynTextNode } from '../../service/dynamic_service';
import { VideoService, CommentItem, ReplyPage, SubReplyPage } from '../../service/video_service';

const GRID_SPACE: number = 5;
const IMG_MAX_RATIO: number = 2.6;

function two(n: number): string {
  const s: string = n.toString();
  return s.length >= 2 ? s : '0' + s;
}

function fmtTime(ts: number): string {
  const d = new Date(ts * 1000);
  return two(d.getMonth() + 1) + '-' + two(d.getDate()) + ' ' + two(d.getHours()) + ':' + two(d.getMinutes());
}

@Entry
@Component
struct DynDetailPage {
  @State item: DynItem | undefined = undefined;
  @State detailLoading: boolean = true;
  @State detailError: string = '';
  private opusOnly: boolean = false;
  private detailGeneration: number = 0;
  private detailGallery: string = nextGalleryId();
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  private cardW: number = 340;

  // ===== 评论（spec-08 V2，type=17 动态评论）=====
  private dynId: string = '';
  private ds: BasicDataSource<CommentItem> = new BasicDataSource<CommentItem>();
  @State topItems: CommentItem[] = [];
  @State replyTotal: number = 0;
  @State sortMode: number = 3; // 3=按热度 2=按时间
  @State firstLoading: boolean = false;
  @State replyErr: string = '';
  @State replyEnd: boolean = false;
  @State tick: number = 0; // 楼中楼就地刷新用（LazyForEach key 带 tick）
  /** 楼中楼面板 */
  private nextOffset: string = '';
  private loadingMore: boolean = false;
  private destroyed: boolean = false;
  private commentGeneration: number = 0;

  aboutToAppear(): void {
    try {
      const disp = display.getDefaultDisplaySync();
      this.cardW = px2vp(disp.width) - 24;
    } catch (e) {
      this.cardW = 340;
    }
    const pm: Record<string, string> | undefined = router.getParams() as Record<string, string> | undefined;
    if (pm !== undefined) {
      const id: string | undefined = pm['id'];
      if (id !== undefined) {
        this.dynId = id;
        this.opusOnly = pm['opus'] === '1';
        this.loadDetail();
      }
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.commentGeneration++;
    this.detailGeneration++;
  }

  private async loadDetail(): Promise<void> {
    const version: number = ++this.detailGeneration;
    this.detailLoading = true; this.detailError = '';
    try {
      const item: DynItem = await DynamicService.loadDetail(this.dynId, this.opusOnly);
      if (this.destroyed || version !== this.detailGeneration) { return; }
      this.item = item; this.replyTotal = item.commentCount; this.loadComments(true);
    } catch (e) {
      if (!this.destroyed && version === this.detailGeneration) { this.detailError = (e as Error).message || '详情加载失败'; }
    } finally {
      if (!this.destroyed && version === this.detailGeneration) { this.detailLoading = false; }
    }
  }

  private openRich(node: DynTextNode): void {
    if (node.mid > 0) { openMember(node.mid); return; }
    const video: RegExpMatchArray | null = node.link.match(/BV[0-9A-Za-z]{10}/);
    if (video) { router.pushUrl({ url: 'pages/video/VideoDetailPage', params: { 'bvid': video[0] } }); return; }
    const url: string = node.link.startsWith('//') ? 'https:' + node.link : node.link;
    if (!/^https?:\/\//.test(url)) { return; }
    const context = getContext(this) as common.UIAbilityContext;
    context.startAbility({ action: 'ohos.want.action.viewData', uri: url }).catch(() => {
      if (!this.destroyed) { promptAction.showToast({ message: '无法打开链接' }); }
    });
  }

  @Builder
  Paragraphs(blocks: DynParagraph[]) {
    Column({ space: 12 }) {
      ForEach(blocks, (block: DynParagraph, index: number) => {
        if (block.text.length > 0) {
          Text() {
            ForEach(block.text, (node: DynTextNode) => {
              Span(node.text).fontSize(block.heading ? 20 : Math.max(13, Math.min(24, node.size)))
                .fontWeight(node.bold || block.heading ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(node.italic ? FontStyle.Italic : FontStyle.Normal)
                .decoration({ type: node.strike ? TextDecorationType.LineThrough : TextDecorationType.None })
                .fontColor(node.link || node.mid > 0 ? $r('app.color.brand_pink') : $r('app.color.text_primary'))
                .onClick(() => { this.openRich(node); })
            })
          }.width('100%').lineHeight(28)
            .padding(block.quote ? 10 : 0).backgroundColor(block.quote ? $r('app.color.btn_soft_bg') : Color.Transparent)
        }
        if (block.divider) { Divider().color($r('app.color.divider')) }
        if (block.card) {
          Row({ space: 10 }) {
            if (block.card.cover) {
              Column() { AsyncImage({ src: block.card.cover, w: 240, h: 150 }) }.width(100).height(62.5).clip(true).borderRadius(4)
            }
            Text(block.card.title).fontSize(14).fontColor($r('app.color.text_primary')).maxLines(3).layoutWeight(1)
          }.width('100%').padding(10).borderRadius(6).backgroundColor($r('app.color.btn_soft_bg'))
            .onClick(() => { if (block.card) { this.openRich({ text: '', link: block.card.link, mid: 0,
              bold: false, italic: false, strike: false, size: 16 }); } })
        }
        ForEach(block.pics, (pic: DynPic, pictureIndex: number) => {
          Column() {
            GalleryThumbnail({ urls: block.pics.map((p: DynPic) => p.src), index: pictureIndex,
              groupId: this.detailGallery + '_' + index.toString(), w: 960, h: 2048 })
          }.width('100%').aspectRatio(Math.max(0.01, pic.width / Math.max(1, pic.height))).borderRadius(6).clip(true)
        }, (p: DynPic) => p.src)
      })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  // ===== 评论加载（对齐视频详情页实现；oid/type 取自 basic.comment_id_str / comment_type）=====

  private commentOid(): string {
    if (this.item !== undefined && this.item.commentId.length > 0) {
      return this.item.commentId;
    }
    return this.dynId;
  }

  private commentType(): number {
    return this.item !== undefined ? this.item.commentType : 17;
  }

  private async loadComments(reset: boolean): Promise<void> {
    if (this.destroyed || (!reset && this.loadingMore) || this.dynId.length === 0) {
      return;
    }
    if (!reset && this.replyEnd) {
      return;
    }
    this.loadingMore = true;
    const generation: number = reset ? ++this.commentGeneration : this.commentGeneration;
    this.replyErr = '';
    if (reset) {
      this.firstLoading = true;
      this.nextOffset = '';
      this.replyEnd = false;
    }
    try {
      const r: ReplyPage = await VideoService.dynReply(this.commentOid(), this.commentType(), this.nextOffset, this.sortMode);
      if (this.destroyed || generation !== this.commentGeneration) {
        return;
      }
      if (reset) {
        this.ds.reload(r.items);
        this.topItems = r.topItems;
      } else {
        this.ds.append(r.items);
      }
      this.nextOffset = r.nextOffset;
      this.replyEnd = r.isEnd;
      if (r.total > 0) {
        this.replyTotal = r.total;
      }
    } catch (e) {
      if (!this.destroyed && generation === this.commentGeneration) {
        this.replyErr = '评论加载失败，点击重试';
        this.replyEnd = true;
      }
    }
    if (!this.destroyed && generation === this.commentGeneration) {
      this.loadingMore = false;
      this.firstLoading = false;
    }
  }

  private switchSort(): void {
    this.sortMode = this.sortMode === 3 ? 2 : 3;
    this.tick = this.tick + 1;
    this.loadComments(true);
  }

  /** 楼中楼：点击「共N条回复」→ 进入「评论详情」页 */
  private toggleSub(item: CommentItem): void {
    SubReplyArgs.set(item, this.item !== undefined ? this.item.author.mid : 0, 0, this.commentOid(), this.commentType());
    router.pushUrl({ url: 'pages/video/SubReplyPage' });
  }

  private loadSubMore(item: CommentItem): void {
    this.toggleSub(item);
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  private galleryId: string = nextGalleryId();
  private pictureUrls(pics: DynPic[]): string[] { return pics.map((p: DynPic) => p.src); }

  // ===== 图片网格（Nara _calcGridInfo 同规则） =====

  private cellW(n: number): number {
    const w: number = this.cardW > 0 ? this.cardW : 340;
    if (n === 2) {
      return (w - GRID_SPACE) / 2;
    }
    return (w - 2 * GRID_SPACE) / 3;
  }

  private singleW(p: DynPic): number {
    const w: number = this.cardW > 0 ? this.cardW : 340;
    const cell: number = (w - 2 * GRID_SPACE) / 3;
    const rw: number = p.width > 0 && p.height > 0 ? p.width / p.height : 1.6;
    const rh: number = p.width > 0 && p.height > 0 ? p.height / p.width : 0.625;
    let iw: number = rw > 1.45 ? w : ((rw >= 1 || (p.height > p.width && rh < 1.5)) ? 2 * cell : 1.5 * cell);
    if (p.width !== 1 && p.width > 0) {
      iw = Math.min(iw, p.width);
    }
    return iw;
  }

  private singleRatio(p: DynPic): number {
    const rh: number = p.width > 0 && p.height > 0 ? p.height / p.width : 0.625;
    return 1 / Math.min(rh, IMG_MAX_RATIO);
  }

  private perRowOf(n: number): number {
    if (n === 4 || n === 2) {
      return 2;
    }
    return 3;
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

  private sliceRow(pics: DynPic[], start: number, perRow: number): DynPic[] {
    return pics.slice(start, start + perRow);
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
  PicsGrid(pics: DynPic[]) {
    Column({ space: GRID_SPACE }) {
      if (pics.length === 1) {
        Column() {
          GalleryThumbnail({ urls: this.pictureUrls(pics), thumbs: this.pictureUrls(pics), index: 0,
            groupId: this.galleryId + pics[0].src, w: 720, h: 720 })
        }
        .width(this.singleW(pics[0]))
        .aspectRatio(this.singleRatio(pics[0]))
        .borderRadius(6)
        .clip(true)
        .backgroundColor($r('app.color.btn_soft_bg'))
      } else {
        ForEach(this.rowStarts(pics.length, this.perRowOf(pics.length)), (rowStart: number) => {
          Row({ space: GRID_SPACE }) {
            ForEach(this.sliceRow(pics, rowStart, this.perRowOf(pics.length)), (p: DynPic, idx: number) => {
              Column() {
                GalleryThumbnail({ urls: this.pictureUrls(pics), thumbs: this.pictureUrls(pics), index: rowStart + idx,
                  groupId: this.galleryId + pics[0].src, w: 360, h: 360 })
              }
              .layoutWeight(1)
              .aspectRatio(1)
              .borderRadius(6)
              .clip(true)
              .backgroundColor($r('app.color.btn_soft_bg'))
            }, (p: DynPic, idx: number) => p.src + '_' + idx.toString())
            ForEach(this.emptyCount(pics.length, rowStart, this.perRowOf(pics.length)), (e: number) => {
              Column()
                .layoutWeight(1)
                .aspectRatio(1)
            }, (e: number) => 'e' + rowStart.toString() + '_' + e.toString())
          }
          .width('100%')
        }, (rowStart: number) => 'r' + rowStart.toString())
      }
    }
    .width(pics.length === 4 ? (2 * this.cellW(4) + GRID_SPACE) : '100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 分段条：转发 / 评论 / 赞（Nara 动态详情顶部；本项目仅评论可点） */
  @Builder
  SegmentBar(d: DynItem) {
    Row() {
      Column({ space: 6 }) {
        Text('转发 ' + formatPlayCount(d.forwardCount))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Divider().strokeWidth(2).color(Color.Transparent).width(26).margin({ top: 4 })
      }
      .layoutWeight(1)
      .onClick(() => {
        this.toast('转发列表暂未开放');
      })

      Column({ space: 6 }) {
        Text('评论 ' + formatPlayCount(this.replyTotal > 0 ? this.replyTotal : d.commentCount))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Divider().strokeWidth(2).color($r('app.color.brand_pink')).width(26).margin({ top: 4 })
      }
      .layoutWeight(1)

      Column({ space: 6 }) {
        Text('赞 ' + formatPlayCount(d.likeCount))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Divider().strokeWidth(2).color(Color.Transparent).width(26).margin({ top: 4 })
      }
      .layoutWeight(1)
      .onClick(() => {
        this.toast('点赞列表暂未开放');
      })
    }
    .width('100%')
    .height(46)
    .margin({ top: 6 })
  }

  /** 排序头：最热评论 / 最新评论 + 切换 */
  @Builder
  SortHeader() {
    Row() {
      Text(this.sortMode === 3 ? '最热评论' : '最新评论')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Row({ space: 4 }) {
        Image($r('app.media.icon_sort'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.text_secondary'))
        Text(this.sortMode === 3 ? '最热' : '按时间')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .onClick(() => {
        this.switchSort();
      })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
  }

  @Builder
  ForwardBlock(orig: DynItem) {
    Column({ space: 5 }) {
      Text(orig.author.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      if (orig.text.length > 0) {
        Text(orig.text)
          .fontSize(15)
          .lineHeight(24)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      if (orig.kind === 'av' && orig.archive !== undefined) {
        Row() {
          Text(orig.archive.title)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('视频 >')
            .fontSize(12)
            .fontColor($r('app.color.brand_pink'))
        }
        .width('100%')
        .onClick(() => {
          if (orig.archive !== undefined) {
            const params: Record<string, string> = { 'bvid': orig.archive.bvid };
            router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
          }
        })
      } else if (orig.pics !== undefined && orig.pics.length > 0) {
        this.PicsGrid(orig.pics)
      }
    }
    .width('100%')
    .padding({ left: 15, right: 15, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.btn_soft_bg'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 与Nara默认Cupertino一致：300ms，底页1/3视差。 */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE })
      .translate({ x: '100%' })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // 顶栏
        Row({ space: 8 }) {
          Image($r('app.media.icon_arrow_left'))
            .width(22).height(22)
            .fillColor($r('app.color.text_primary'))
            .padding({ left: 6, right: 6 })
            .onClick(() => {
              router.back();
            })
          Text('动态详情')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 8, right: 12, top: 10 + this.statusBarH, bottom: 10 })
        .backgroundColor($r('app.color.card_bg'))

        if (this.detailLoading) {
          Column() { LoadingProgress().width(36).height(36) }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.detailError) {
          Column({ space: 14 }) {
            Text(this.detailError).fontSize(14).fontColor($r('app.color.text_secondary'))
            Button('重试').onClick(() => { this.loadDetail(); })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.item !== undefined) {
          List() {
            ListItem() {
              Column({ space: 10 }) {
                // 作者行
                Row({ space: 10 }) {
                  Column() {
                    AsyncImage({ src: this.item.author.face, w: 120, h: 120 })
                  }
                  .width(40)
                  .height(40)
                  .borderRadius(20)
                  .clip(true)
                  .backgroundColor($r('app.color.btn_soft_bg'))
                  .onClick(() => { if (this.item) { openMember(this.item.author.mid); } })
                  Column({ space: 2 }) {
                    Text(this.item.author.name)
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                    Text(this.item.author.pubTs > 0
                      ? fmtTime(this.item.author.pubTs)
                      : this.item.author.pubText)
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  .onClick(() => { if (this.item) { openMember(this.item.author.mid); } })
                }
                .width('100%')

                // 正文（完整）
                if (this.item.text.length > 0) {
                  Text(this.item.text)
                    .fontSize(15)
                    .lineHeight(26)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                }

                // 类型内容
                if (this.item.paragraphs) {
                  this.Paragraphs(this.item.paragraphs)
                } else if (this.item.kind === 'av' && this.item.archive !== undefined) {
                  Row() {
                    Text(this.item.archive.title)
                      .fontSize(15)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text('视频 >')
                      .fontSize(12)
                      .fontColor($r('app.color.brand_pink'))
                  }
                  .width('100%')
                  .padding(12)
                  .backgroundColor($r('app.color.btn_soft_bg'))
                  .borderRadius(6)
                  .onClick(() => {
                    if (this.item !== undefined && this.item.archive !== undefined) {
                      const params: Record<string, string> = { 'bvid': this.item.archive.bvid };
                      router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
                    }
                  })
                } else if (this.item.pics !== undefined && this.item.pics.length > 0) {
                  this.PicsGrid(this.item.pics)
                } else if (this.item.kind === 'forward' && this.item.orig !== undefined) {
                  this.ForwardBlock(this.item.orig)
                }

                // 互动提示行
                if (this.item.interactText.length > 0) {
                  Text(this.item.interactText)
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                }

                // 分段条（转发 / 评论 / 赞，评论可用）
                this.SegmentBar(this.item)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 0 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            ListItem() {
              this.SortHeader()
            }
            .width('100%')

            // 置顶评论
            ForEach(this.topItems, (t: CommentItem) => {
              ListItem() {
                Column() {
                  CommentItemView({
                    item: t,
                    upMid: this.item !== undefined ? this.item.author.mid : 0,
                    onOpenSub: (it: CommentItem) => {
                      this.toggleSub(it);
                    },
                    onSubMore: (it: CommentItem) => {
                      this.loadSubMore(it);
                    }
                  })
                }
                .width('100%')
                .backgroundColor($r('app.color.comment_top_bg'))
              }
              .width('100%')
            }, (t: CommentItem) => 'dtop_' + t.rpid.toString() + '_'
              + t.subPage.toString() + (t.expanded ? 'e' : 'c'))

            if (this.firstLoading) {
              ForEach([0, 1, 2, 3, 4], (i: number) => {
                ListItem() {
                  CommentSkeleton({ variant: i })
                }
                .width('100%')
              }, (i: number) => 'dsk_' + i.toString())
            } else {
              LazyForEach(this.ds, (c: CommentItem) => {
                ListItem() {
                  CommentItemView({
                    item: c,
                    upMid: this.item !== undefined ? this.item.author.mid : 0,
                    onOpenSub: (it: CommentItem) => {
                      this.toggleSub(it);
                    },
                    onSubMore: (it: CommentItem) => {
                      this.loadSubMore(it);
                    }
                  })
                }
                .width('100%')
              }, (c: CommentItem) => c.rpid.toString() + '_' + c.subPage.toString()
                + (c.expanded ? 'e' : 'c') + '_' + this.tick.toString())
            }

            // 页脚
            ListItem() {
              Column() {
                if (this.replyErr.length > 0) {
                  Text(this.replyErr)
                    .fontSize(12)
                    .fontColor($r('app.color.brand_pink'))
                    .onClick(() => {
                      this.loadComments(true);
                    })
                } else if (this.replyEnd && this.ds.size() === 0 && this.topItems.length === 0) {
                  Text('还没有评论，快来抢沙发吧')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                } else if (this.replyEnd) {
                  Text('没有更多评论了')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                } else {
                  Text('加载中…')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
              }
              .width('100%')
              .height(110)
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
          }
          .cachedCount(3)
          .layoutWeight(1)
          .width('100%')
          .divider({ strokeWidth: 0.3, color: '#14000000', startMargin: 55, endMargin: 15 })
          .onReachEnd(() => {
            this.loadComments(false);
          })
        } else {
          Column() {
            Text('内容已失效')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
