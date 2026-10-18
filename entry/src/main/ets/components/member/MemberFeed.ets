import { MemberService, MemberEntry, MemberResult } from '../../service/member_service';
import { FavService, FavPage } from '../../service/fav_service';
import { VideoItem } from '../../model/video_item';
import { BasicDataSource } from '../../common/list_data_source';
import { VideoCard } from '../VideoCard';
import { DynamicCard } from '../dynamic/DynamicCard';
import { NARA_SCROLL_FRICTION } from '../../common/nara_motion';
import { MemberCollectionCard, MemberOpusCard } from './MemberCards';

export const MEMBER_NESTED: NestedScrollOptions = {
  scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST
};

@Component
export struct MemberFeed {
  onTotal: (total: number) => void = () => {};
  @Prop mid: number = 0;
  @Prop kind: string = 'video';
  @Prop resourceId: number = 0;
  @Prop keyword: string = '';
  @Prop @Watch('reloadQuery') queryRevision: number = 0;
  @State count: number = 0;
  @State total: number = 0;
  @State busy: boolean = false;
  @State error: string = '';
  @State end: boolean = false;
  @State refreshing: boolean = false;
  @State order: string = 'pubdate';
  @State ascending: boolean = false;
  @State feedWidth: number = 412;
  @StorageProp('navBarHeight') navH: number = 0;
  private ds: BasicDataSource<MemberEntry> = new BasicDataSource<MemberEntry>();
  listScroller: Scroller = new Scroller();
  private next: string = '';
  private page: number = 1;
  private generation: number = 0;
  private destroyed: boolean = false;
  private keys: Set<string> = new Set<string>();
  private cursors: Set<string> = new Set<string>();

  aboutToAppear(): void { this.destroyed = false; this.load(true); }
  aboutToDisappear(): void { this.destroyed = true; this.generation++; }
  private reloadQuery(): void { this.load(true); }
  private async fetch(): Promise<MemberResult> {
    if (this.kind === 'like' || this.kind === 'coin') { return MemberService.recent(this.mid, this.kind); }
    if (this.kind === 'dynamic') { return MemberService.dynamics(this.mid, this.next, this.keyword, this.page); }
    if (this.kind === 'opus') { return MemberService.opus(this.mid, this.next, this.page); }
    if (this.kind === 'collections') { return MemberService.collections(this.mid, this.page); }
    if (this.kind === 'season' || this.kind === 'series') {
      return MemberService.collectionVideos(this.mid, this.resourceId, this.kind, this.page, this.ascending);
    }
    if (this.kind === 'favorite' || this.kind === 'subscription') {
      const data: FavPage = await FavService.folderItems(this.resourceId, this.page, this.kind === 'subscription');
      return { items: data.items.map((v: VideoItem): MemberEntry => ({ key: v.key, video: v })),
        next: (this.page + 1).toString(), hasMore: data.hasMore, total: 0 };
    }
    return MemberService.videos(this.mid, this.page, this.order, this.keyword, this.ascending);
  }
  private async load(reset: boolean): Promise<void> {
    if (this.destroyed || (!reset && (this.busy || this.end))) { return; }
    if (this.queryRevision < 0) { return; }
    const version: number = reset ? ++this.generation : this.generation;
    if (reset) {
      this.next = ''; this.page = 1; this.end = false; this.error = ''; this.keys.clear(); this.cursors.clear();
      this.ds.reload([]); this.count = 0;
      try { this.listScroller.scrollTo({ xOffset: 0, yOffset: 0 }); } catch (_) {}
    }
    this.busy = true; this.error = '';
    try {
      const data: MemberResult = await this.fetch();
      if (this.destroyed || version !== this.generation) { return; }
      const unique: MemberEntry[] = data.items.filter((e: MemberEntry) => {
        if (this.keys.has(e.key)) { return false; } this.keys.add(e.key); return true;
      });
      this.ds.append(unique); this.count = this.ds.size(); this.total = data.total;
      this.onTotal(data.total);
      this.end = !data.hasMore || this.cursors.has(data.next) || data.next === this.next;
      this.cursors.add(data.next); this.next = data.next; this.page++;
    } catch (e) {
      if (!this.destroyed && version === this.generation) { this.error = (e as Error).message || '请求失败，请重试'; }
    } finally {
      if (!this.destroyed && version === this.generation) { this.busy = false; this.refreshing = false; }
    }
  }
  @Builder
  SortRow() {
    if (this.kind === 'video' || this.kind === 'season' || this.kind === 'series') {
      Row({ space: 6 }) {
        Text(this.kind === 'video' ? (this.order === 'pubdate' ? '最新发布' : '最多播放') : '视频列表')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .onClick(() => { if (this.kind === 'video') {
            this.order = this.order === 'pubdate' ? 'click' : 'pubdate'; this.load(true);
          } })
        Text(this.total > 0 ? this.total.toString() : '').fontSize(12).fontColor($r('app.color.text_secondary'))
        Blank()
        Row({ space: 4 }) {
          Image($r('app.media.icon_sort')).width(16).height(16).fillColor($r('app.color.text_secondary'))
          Text(this.ascending ? '正序' : '倒序').fontSize(13).fontColor($r('app.color.text_secondary'))
        }.height(40).onClick(() => { this.ascending = !this.ascending; this.load(true); })
      }.width('100%').height(45).padding({ left: 14, right: 8, top: 2.5, bottom: 2.5 })
        .backgroundColor($r('app.color.bg_page'))
    }
  }
  @Builder
  Footer() {
    Column({ space: 10 }) {
      if (this.busy) { LoadingProgress().width(26).height(26) }
      Text(this.error || (this.busy ? '加载中…' : this.end ? (this.count === 0 ? '暂无公开内容' : '没有更多了') : '加载更多'))
        .fontSize(12).fontColor(this.error ? $r('app.color.brand_pink') : $r('app.color.text_secondary'))
        .onClick(() => { if (!this.busy) { this.load(this.count === 0); } })
    }.width('100%').height(this.count === 0 ? 280 : 125 + this.navH).justifyContent(FlexAlign.Center)
  }
  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      if (this.kind === 'opus') {
        WaterFlow({ scroller: this.listScroller, footer: () => { this.Footer(); } }) {
          LazyForEach(this.ds, (e: MemberEntry) => {
            FlowItem() { if (e.opus) { MemberOpusCard({ model: e.opus, cardWidth: (this.feedWidth - 36) / 2 }) } }
              .width((this.feedWidth - 36) / 2)
          }, (e: MemberEntry) => e.key)
        }.columnsTemplate('1fr 1fr').columnsGap(12).rowsGap(12).padding({ left: 12, right: 12 })
          .width('100%').height('100%').nestedScroll(MEMBER_NESTED).edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
          .friction(NARA_SCROLL_FRICTION)
          .onReachEnd(() => { if (!this.error) { this.load(false); } })
      } else {
        List({ scroller: this.listScroller }) {
          ListItem() { this.SortRow() }
          LazyForEach(this.ds, (e: MemberEntry) => {
            ListItem() {
              if (e.video) { VideoCard({ model: e.video, spaceCard: this.kind === 'video' || this.kind === 'season' || this.kind === 'series' }) }
              else if (e.dynamic) {
                Column() {
                  if (e.dynamic.pinned) {
                    Text(e.dynamic.pinned).fontSize(12).fontColor($r('app.color.brand_pink'))
                      .width('100%').padding({ left: 12, top: 8 })
                  }
                  DynamicCard({ model: e.dynamic })
                }
              } else if (e.collection) { MemberCollectionCard({ model: e.collection, mid: this.mid }) }
            }
          }, (e: MemberEntry) => e.key)
          ListItem() { this.Footer() }
        }.width('100%').height('100%').cachedCount(3).scrollBar(BarState.Off)
          .nestedScroll(MEMBER_NESTED).edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
          .friction(NARA_SCROLL_FRICTION)
          .onReachEnd(() => { if (!this.error) { this.load(false); } })
      }
    }.width('100%').height('100%').onRefreshing(() => { this.refreshing = true; this.load(true); })
      .onAreaChange((_old: Area, area: Area) => { this.feedWidth = Number(area.width); })
  }
}
