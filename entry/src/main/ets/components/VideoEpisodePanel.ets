/** Nara PagesPanel / SeasonPanel / EpisodePanel：同页选集，不创建新播放器。 */
import { FrameCallback } from '@ohos.arkui.UIContext';
import { VideoDetail, VideoPageInfo, VideoEpisode, VideoSeasonSection } from '../service/video_service';
import { BasicDataSource } from '../common/list_data_source';
import { AsyncImage } from './AsyncImage';
import { formatDuration, formatPlayCount } from './VideoCard';

class EpisodeLayoutCallback extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_time: number): void { this.action(); this.action = () => {}; }
}

export interface EpisodeSelection { bvid: string; cid: number; }

interface VideoPartsSource { bvid: string; pages: VideoPageInfo[]; }

/** 仅在详情提交/面板重载时生成，避免V1复杂Prop复用与每帧序列化。 */
export function makeVideoPartsSource(bvid: string, pages: VideoPageInfo[]): string {
  const source: VideoPartsSource = { bvid: bvid, pages: pages };
  return JSON.stringify(source);
}

/** 分P条目步距150，卡片140+右距10；最后一项没有右距。 */
@Component
export struct VideoPartsStrip {
  @Prop @Watch('locate') currentCid: number = 0;
  @Prop @Watch('onSourceChanged') source: string = '';
  @Prop showHeader: boolean = true;
  @State private pages: VideoPageInfo[] = [];
  @State private bvid: string = '';
  onOpen: () => void = () => {};
  onSelect: (selection: EpisodeSelection) => void = () => {};
  private scroller: Scroller = new Scroller();
  private ds: BasicDataSource<VideoPageInfo> = new BasicDataSource<VideoPageInfo>();
  private destroyed: boolean = false;

  aboutToAppear(): void { this.destroyed = false; this.onSourceChanged(); }
  aboutToDisappear(): void { this.destroyed = true; }
  private onSourceChanged(): void {
    try {
      const source: VideoPartsSource = JSON.parse(this.source) as VideoPartsSource;
      this.bvid = source.bvid; this.pages = source.pages;
    } catch (_) { this.bvid = ''; this.pages = []; }
    this.ds.reload(this.pages); this.locate();
  }
  private locate(): void {
    this.getUIContext().postFrameCallback(new EpisodeLayoutCallback(() => {
      if (this.destroyed) { return; }
      const index: number = Math.max(0, this.pages.findIndex((p: VideoPageInfo): boolean => p.cid === this.currentCid));
      try { this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER); } catch (_) {}
    }));
  }
  private partTitle(): string { return this.pages.find((p: VideoPageInfo): boolean => p.cid === this.currentCid)?.part || ''; }

  build() {
    Column() {
      if (this.showHeader) {
        Row({ space: 4 }) {
          Text('视频选集').fontSize(14).fontColor($r('app.color.text_primary'))
          Text('正在播放：' + this.partTitle()).fontSize(12).fontColor($r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text('共' + this.pages.length.toString() + '集').fontSize(13).fontColor($r('app.color.brand_pink'))
            .height(34).margin({ left: 6 }).id('video_parts_all').onClick(this.onOpen)
        }.width('100%').height(44).padding({ top: 8, bottom: 2 })
      }
      List({ scroller: this.scroller }) {
        LazyForEach(this.ds, (page: VideoPageInfo, index: number) => {
          ListItem() {
            Stack({ alignContent: Alignment.BottomEnd }) {
              Text() {
                if (this.currentCid === page.cid) {
                  // SVG右侧含6vp透明间距，第二行跟随正文起行而非缩进图标列。
                  ImageSpan($r('app.media.icon_living_inline')).width(18).height(12)
                    .verticalAlign(ImageSpanAlignment.CENTER).objectFit(ImageFit.Contain)
                }
                Span(page.part)
              }.fontSize(13).lineHeight(14.3)
                .fontColor(this.currentCid === page.cid ? $r('app.color.brand_pink') : $r('app.color.text_primary'))
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%').height('100%').padding({ left: 8, right: 8 })
              Text(page.page.toString()).fontSize(10.5).fontColor($r('app.color.member_on_secondary_container'))
                .backgroundColor($r('app.color.video_part_badge_bg'))
                .padding({ left: 4, right: 4 }).borderRadius({ topLeft: 2, bottomRight: 6 })
            }.width(index === this.pages.length - 1 ? 150 : 140).height(45)
              .backgroundColor($r('app.color.btn_soft_bg')).borderRadius(6).clip(true)
              .id('video_part_' + page.cid.toString()).accessibilityText('第' + page.page.toString() + '集 ' + page.part)
              .accessibilitySelected(this.currentCid === page.cid)
              .onClick(() => { this.onSelect({ bvid: this.bvid, cid: page.cid }); })
          }.width(150).height(45)
        }, (page: VideoPageInfo): string => page.cid.toString())
      }.listDirection(Axis.Horizontal).scrollBar(BarState.Off).height(45).width('100%').cachedCount(1)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

interface PanelEntry {
  key: string; bvid: string; cid: number; title: string; cover: string; duration: number; pubdate: number;
  viewCount: number; danmakuCount: number; part: boolean; index: number; partsSource: string;
}

@Component
export struct VideoEpisodePanel {
  @Prop detail: VideoDetail;
  @Prop currentCid: number = 0;
  @Prop seasonMode: boolean = false;
  @Prop initialSection: number = 0;
  onClose: () => void = () => {};
  onSelect: (selection: EpisodeSelection) => void = () => {};
  @State private section: number = 0;
  @State private reversed: boolean = false;
  private scroller: Scroller = new Scroller();
  private ds: BasicDataSource<PanelEntry> = new BasicDataSource<PanelEntry>();
  private entries: PanelEntry[] = [];
  private destroyed: boolean = false;
  @StorageProp('navBarHeight') navBarH: number = 0;

  aboutToAppear(): void {
    this.destroyed = false;
    this.section = this.initialSection;
    this.reload(); this.locate();
  }
  aboutToDisappear(): void { this.destroyed = true; }
  private sections(): VideoSeasonSection[] { return this.detail.season?.sections || []; }
  private reload(): void {
    const entries: PanelEntry[] = [];
    if (this.seasonMode) {
      const episodes: VideoEpisode[] = this.sections()[this.section]?.episodes || [];
      episodes.forEach((ep: VideoEpisode, index: number): void => {
        entries.push({ key: ep.bvid + ':' + ep.cid.toString(), bvid: ep.bvid, cid: ep.cid, title: ep.title,
          cover: ep.cover, duration: ep.duration, pubdate: ep.pubdate, viewCount: ep.viewCount,
          danmakuCount: ep.danmakuCount, part: false, index: index + 1,
          partsSource: ep.pages.length > 1 ? makeVideoPartsSource(ep.bvid,
            ep.bvid === this.detail.bvid ? this.detail.pages : ep.pages) : '' });
      });
    } else {
      this.detail.pages.forEach((p: VideoPageInfo, index: number): void => {
        entries.push({ key: this.detail.bvid + ':' + p.cid.toString(), bvid: this.detail.bvid, cid: p.cid,
          title: p.part, cover: p.cover || this.detail.cover, duration: p.duration, pubdate: p.pubdate || 0,
          viewCount: -1, danmakuCount: -1, part: true, index: index + 1, partsSource: '' });
      });
    }
    this.entries = this.reversed ? entries.reverse() : entries;
    this.ds.reload(this.entries);
  }
  private isCurrent(entry: PanelEntry): boolean {
    return entry.bvid === this.detail.bvid && (this.seasonMode || entry.cid === this.currentCid);
  }
  private locate(): void {
    if (this.seasonMode && this.section !== this.initialSection) {
      this.section = this.initialSection; this.reload();
    }
    this.getUIContext().postFrameCallback(new EpisodeLayoutCallback(() => {
      if (this.destroyed) { return; }
      const index: number = Math.max(0, this.entries.findIndex((e: PanelEntry): boolean => this.isCurrent(e)));
      try { this.scroller.scrollToIndex(index + 1, false, ScrollAlign.START); } catch (_) {}
    }));
  }
  private date(value: number): string {
    const d: Date = new Date(value * 1000);
    return d.getFullYear().toString() + '-' + (d.getMonth() + 1).toString().padStart(2, '0') + '-' + d.getDate().toString().padStart(2, '0');
  }

  @Builder
  Tool(icon: Resource, label: string, id: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Image(icon).width(22).height(22).fillColor($r('app.color.text_primary'))
    }.width(35).height(44).padding(0).backgroundColor(Color.Transparent).id(id).accessibilityText(label).onClick(action)
  }

  @Builder
  Entry(entry: PanelEntry) {
    Column() {
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          AsyncImage({ src: entry.cover, w: 320, h: 200 }).width(160).height(100)
          if (entry.duration > 0) {
            Text(formatDuration(entry.duration)).fontSize(10).fontColor(Color.White).backgroundColor('#80000000')
              .borderRadius(4).padding({ left: 4, right: 4, top: 1, bottom: 1 }).margin({ right: 6, bottom: 6 })
          }
          if (entry.part) {
            Text(entry.index.toString()).fontSize(12).fontColor($r('app.color.member_on_secondary_container'))
              .backgroundColor($r('app.color.member_secondary_container')).padding({ left: 4, right: 4 })
              .borderRadius({ bottomLeft: 4, topRight: 10 }).position({ right: 0, top: 0 })
          }
        }.width(160).height(100).borderRadius(10).clip(true).backgroundColor($r('app.color.btn_soft_bg'))
        Column() {
          Text(entry.title).fontSize(14).lineHeight(19.88).letterSpacing(0.3)
            .fontWeight(this.isCurrent(entry) ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.isCurrent(entry) ? $r('app.color.brand_pink') : $r('app.color.text_primary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').layoutWeight(1)
          if (entry.pubdate > 0) { Text(this.date(entry.pubdate)).fontSize(12).lineHeight(12).fontColor($r('app.color.text_secondary')) }
          if (entry.viewCount >= 0) {
            Row({ space: 8 }) {
              Row({ space: 2 }) {
                Image($r('app.media.icon_play')).width(13).height(13).fillColor($r('app.color.text_secondary'))
                Text(formatPlayCount(entry.viewCount)).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              Row({ space: 2 }) {
                Image($r('app.media.icon_danmaku')).width(13).height(13).fillColor($r('app.color.text_secondary'))
                Text(formatPlayCount(entry.danmakuCount)).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
            }.margin({ top: 2 })
          }
        }.layoutWeight(1).height(100).alignItems(HorizontalAlign.Start)
      }.width('100%').height(110).padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .id('episode_' + entry.key).accessibilitySelected(this.isCurrent(entry))
        .onClick(() => { this.onSelect({ bvid: entry.bvid, cid: entry.cid }); })
      if (this.seasonMode && entry.partsSource.length > 0) {
        VideoPartsStrip({ source: entry.partsSource,
          currentCid: entry.bvid === this.detail.bvid ? this.currentCid : 0, showHeader: false,
          onSelect: this.onSelect }).padding({ left: 12, right: 12, top: 5, bottom: 5 })
      }
    }.width('100%')
  }

  build() {
    Column() {
      Row() {
        Text(this.seasonMode ? '合集' : '视频选集').fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
        this.Tool($r('app.media.icon_align_top'), '跳至顶部', 'episode_top', () => { this.scroller.scrollEdge(Edge.Top); })
        this.Tool($r('app.media.icon_align_bottom'), '跳至底部', 'episode_bottom', () => { this.scroller.scrollEdge(Edge.Bottom); })
        this.Tool($r('app.media.icon_locate'), '跳至当前', 'episode_current', () => { this.locate(); })
        this.Tool($r('app.media.icon_sort'), this.reversed ? '顺序显示' : '倒序显示', 'episode_reverse', () => { this.reversed = !this.reversed; this.reload(); })
        this.Tool($r('app.media.icon_clear'), '关闭选集', 'episode_close', this.onClose)
      }.width('100%').height(45).padding({ left: 14, right: 2 }).backgroundColor($r('app.color.card_bg'))
        .border({ width: { bottom: 0.3 }, color: $r('app.color.divider') })
      if (this.seasonMode && this.sections().length > 1) {
        Scroll() {
          Row() {
            ForEach(this.sections(), (section: VideoSeasonSection, index: number) => {
              Text(section.title).fontSize(14).fontColor(index === this.section ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
                .height(45).padding({ left: 16, right: 16 }).id('episode_section_' + index.toString())
                .border({ width: { bottom: index === this.section ? 3 : 0 }, color: $r('app.color.brand_pink') })
                .onClick(() => { this.section = index; this.reload(); this.scroller.scrollEdge(Edge.Top); })
            }, (section: VideoSeasonSection): string => section.id.toString())
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').height(45)
      }
      List({ scroller: this.scroller, space: 2 }) {
        ListItem() { Column().height(5) }
        LazyForEach(this.ds, (entry: PanelEntry) => { ListItem() { this.Entry(entry) } }, (entry: PanelEntry): string => entry.key)
        ListItem() { Column().height(100 + this.navBarH) }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).cachedCount(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.card_bg'))
  }
}
