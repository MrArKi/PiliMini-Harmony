/**
 * 动态卡片（spec-08，复刻 Nara dynamics/widgets）：
 * 作者区 → 正文 → 类型区（AV 视频 / 图文网格 / 转发灰块 / 占位）→ 互动提示 → 行动栏
 * 规格来源：docs/参考-NaraUI基准.md §5（源码实证）
 */
import { router, display } from '@kit.ArkUI';
import { openMember } from '../../common/member_route';
import { AsyncImage } from '../AsyncImage';
import { GalleryThumbnail, nextGalleryId } from '../GalleryThumbnail';
import { formatPlayCount } from '../VideoCard';
import { DynItem, DynAuthor, DynPic, DynamicService } from '../../service/dynamic_service';
import { DynamicVideoCard } from './DynamicVideoCard';

function two(n: number): string {
  const s: string = n.toString();
  return s.length >= 2 ? s : '0' + s;
}

function fmtTime(ts: number): string {
  const d = new Date(ts * 1000);
  return two(d.getMonth() + 1) + '-' + two(d.getDate()) + ' ' + two(d.getHours()) + ':' + two(d.getMinutes());
}

@Component
export struct DynamicCard {
  @Prop model: DynItem;
  private galleryId: string = nextGalleryId();
  private pictureUrls(pics: DynPic[]): string[] { return pics.map((p: DynPic) => p.src); }
  /** 卡片可用宽度（vp；图片网格按 Nara 规则计算，= 屏宽 - 左右 padding） */
  private cardW: number = 340;

  aboutToAppear(): void {
    try {
      const disp = display.getDefaultDisplaySync();
      this.cardW = px2vp(disp.width) - 24;
    } catch (e) {
      this.cardW = 340;
    }
  }

  // ===== 作者行（Nara AuthorPanel：头像 40 / 名字 14sp600 / 时间 11sp） =====
  @Builder
  AuthorRow(a: DynAuthor) {
    Row({ space: 10 }) {
      Column() {
        AsyncImage({ src: a.face, w: 120, h: 120 })
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .clip(true)
      .backgroundColor($r('app.color.btn_soft_bg'))
      .onClick(() => { openMember(a.mid); })

      Column({ space: 2 }) {
        Text(a.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(a.pubTs > 0 ? fmtTime(a.pubTs) : a.pubText)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => { openMember(a.mid); })

    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  // ===== 正文（Nara content_panel：15sp / 行高 24） =====
  @Builder
  DescBlock(item: DynItem) {
    if (item.text.length > 0) {
      Text(item.text)
        .fontSize(15)
        .lineHeight(24)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
    }
  }

  /** Nara pushDynDetail：转发外层与引用块各自按自己的类型分流。 */
  private openItem(item: DynItem, viewComment: boolean = false): void {
    if (!viewComment && item.kind === 'av' && item.archive !== undefined && item.archive.bvid.length > 0) {
      const params: Record<string, string> = { 'bvid': item.archive.bvid };
      router.pushUrl({ url: 'pages/video/VideoDetailPage', params: params });
      return;
    }
    DynamicService.putDetail(item);
    const dp: Record<string, string> = { 'id': item.id };
    if (viewComment) { dp['viewComment'] = '1'; }
    router.pushUrl({ url: 'pages/dynamic/DynDetailPage', params: dp });
  }

  // ===== 图片网格（Nara image_grid_builder._calcGridInfo 1:1 复刻） =====
  private static readonly GRID_SPACE: number = 5;
  private static readonly IMG_MAX_RATIO: number = 2.6;

  /** 网格单元宽：2 图 = (W-s)/2；其余 = (W-2s)/3（4 图也是该单元、2 列） */
  private cellW(n: number): number {
    const w: number = this.cardW > 0 ? this.cardW : 340;
    if (n === 2) {
      return (w - DynamicCard.GRID_SPACE) / 2;
    }
    return (w - 2 * DynamicCard.GRID_SPACE) / 3;
  }

  /** 单图宽度档位（Nara）：>1.45 全宽；≥1 或 (竖图且 h/w<1.5) 2 格；否则 1.5 格；再按原图宽截断 */
  private singleW(p: DynPic): number {
    const w: number = this.cardW > 0 ? this.cardW : 340;
    const cell: number = (w - 2 * DynamicCard.GRID_SPACE) / 3;
    const rw: number = p.width > 0 && p.height > 0 ? p.width / p.height : 1.6;
    const rh: number = p.width > 0 && p.height > 0 ? p.height / p.width : 0.625;
    let iw: number = rw > 1.45 ? w : ((rw >= 1 || (p.height > p.width && rh < 1.5)) ? 2 * cell : 1.5 * cell);
    if (p.width !== 1 && p.width > 0) {
      iw = Math.min(iw, p.width);
    }
    return iw;
  }

  /** 单图宽高比 = w / (w * min(h/w, 2.6)) */
  private singleRatio(p: DynPic): number {
    const rh: number = p.width > 0 && p.height > 0 ? p.height / p.width : 0.625;
    return 1 / Math.min(rh, DynamicCard.IMG_MAX_RATIO);
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
  PicsGrid(pics: DynPic[], inset: boolean) {
    Column({ space: DynamicCard.GRID_SPACE }) {
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
          Row({ space: DynamicCard.GRID_SPACE }) {
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
    // 4 图：2 列 × Nara 单元宽 = (2W-5)/3；其余占满
    .width(pics.length === 4 ? (2 * this.cellW(4) + DynamicCard.GRID_SPACE) : '100%')
    .padding({ left: inset ? 12 : 0, right: inset ? 12 : 0 })
    .alignItems(HorizontalAlign.Start)
  }

  private perRowOf(n: number): number {
    if (n === 4) {
      return 2;
    }
    if (n === 2) {
      return 2;
    }
    return 3;
  }

  // ===== 转发块（Nara forward_panel：全宽浅灰块 h15/v8，无圆角） =====
  @Builder
  ForwardBlock(orig: DynItem) {
    Column({ space: 5 }) {
      Text(orig.author.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .onClick(() => { openMember(orig.author.mid); })
      if (orig.text.length > 0) {
        Text(orig.text)
          .fontSize(14)
          .lineHeight(22)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
      }
      if (orig.kind === 'av' && orig.archive !== undefined) {
        DynamicVideoCard({ archive: orig.archive })
      } else if (orig.kind === 'draw' && orig.pics !== undefined && orig.pics.length > 0) {
        this.PicsGrid(orig.pics, false)
      }
    }
    .width('100%')
    .padding({ left: 15, right: 15, top: 8, bottom: 8 })
    .backgroundColor('#0D000000')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => { this.openItem(orig); })
  }

  // ===== 互动提示行（Nara interaction：左侧 1.5px 竖线 + 13sp） =====
  @Builder
  InteractRow(t: string) {
    Text(t)
      .fontSize(13)
      .lineHeight(17)
      .fontColor('#5C5F66')
      .width('100%')
      .border({
        width: { left: 1.5 },
        color: { left: '#4D9499A0' }
      })
      .padding({ left: 8 })
      .margin({ left: 12, right: 12, top: 6 })
  }

  // ===== 行动栏：每个入口独立命中，评论强制进入当前动态并定位评论 =====
  @Builder
  ActBtn(icon: Resource, label: string, comment: boolean) {
    Row({ space: 4 }) {
      Image(icon)
        .width(16)
        .height(16)
        .fillColor($r('app.color.text_secondary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .onClick(() => { if (comment) { this.openItem(this.model, true); } })
  }

  @Builder
  Actions(item: DynItem) {
    Row() {
      this.ActBtn($r('app.media.icon_forward'), item.forwardCount > 0 ? formatPlayCount(item.forwardCount) : '转发', false)
      this.ActBtn($r('app.media.icon_comment'), item.commentCount > 0 ? formatPlayCount(item.commentCount) : '评论', true)
      this.ActBtn($r('app.media.icon_thumbup'), item.likeCount > 0 ? formatPlayCount(item.likeCount) : '赞', false)
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceAround)
    .padding({ top: 8, bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        this.AuthorRow(this.model.author)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 6 })

      Column({ space: 6 }) {
        this.DescBlock(this.model)

        if (this.model.kind === 'av' && this.model.archive !== undefined) {
          DynamicVideoCard({ archive: this.model.archive })
        } else if (this.model.kind === 'draw' && this.model.pics !== undefined && this.model.pics.length > 0) {
          this.PicsGrid(this.model.pics, true)
        } else if (this.model.kind === 'forward' && this.model.orig !== undefined) {
          this.ForwardBlock(this.model.orig)
        } else if (this.model.kind === 'unsupported') {
          Column() {
            Text('暂不支持的类型（直播 / 番剧 / 投票等）')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#0D000000')
          .alignItems(HorizontalAlign.Center)
        } else if (this.model.text.length === 0) {
          // 兜底：无任何可展示内容（如充电专属动态，接口不下发正文/图片），避免空白卡片
          Column() {
            Text(this.model.onlyFans ? '充电专属动态，暂无法查看' : '该动态暂无内容')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#0D000000')
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 6 })
      .alignItems(HorizontalAlign.Start)
      .onClick(() => { this.openItem(this.model); })

      if (this.model.interactText.length > 0) {
        this.InteractRow(this.model.interactText)
      }

      this.Actions(this.model)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
