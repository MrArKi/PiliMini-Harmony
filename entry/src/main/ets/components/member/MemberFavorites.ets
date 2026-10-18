import { MemberService, MemberFolder, MemberFolderResult } from '../../service/member_service';
import { MemberFolderCard } from './MemberCards';
import { MEMBER_NESTED } from './MemberFeed';
import { NARA_SCROLL_FRICTION } from '../../common/nara_motion';

@Component
export struct MemberFavorites {
  listScroller: Scroller = new Scroller();
  @Prop mid: number = 0;
  @State created: MemberFolder[] = [];
  @State collected: MemberFolder[] = [];
  @State createdOpen: boolean = true;
  @State collectedOpen: boolean = true;
  @State createdMore: boolean = true;
  @State collectedMore: boolean = true;
  @State createdBusy: boolean = false;
  @State collectedBusy: boolean = false;
  @State createdError: string = '';
  @State collectedError: string = '';
  @State refreshing: boolean = false;
  private pages: number[] = [1, 1];
  private generations: number[] = [0, 0];
  private destroyed: boolean = false;
  aboutToAppear(): void { this.destroyed = false; this.refresh(); }
  aboutToDisappear(): void { this.destroyed = true; this.generations[0]++; this.generations[1]++; }
  private refresh(): void { this.load(false, true); this.load(true, true); }
  private async load(collected: boolean, reset: boolean = false): Promise<void> {
    const i: number = collected ? 1 : 0;
    if (this.destroyed || (!reset && (collected ? this.collectedBusy : this.createdBusy))) { return; }
    if (!reset && !(collected ? this.collectedMore : this.createdMore) && !(collected ? this.collectedError : this.createdError)) { return; }
    const generation: number = reset ? ++this.generations[i] : this.generations[i];
    if (reset) { this.pages[i] = 1; }
    if (collected) { this.collectedBusy = true; this.collectedError = ''; }
    else { this.createdBusy = true; this.createdError = ''; }
    try {
      const result: MemberFolderResult = await MemberService.folders(this.mid, this.pages[i], collected);
      if (this.destroyed || generation !== this.generations[i]) { return; }
      const old: MemberFolder[] = reset ? [] : collected ? this.collected : this.created;
      const ids: Set<number> = new Set<number>(old.map((f: MemberFolder) => f.id));
      const all: MemberFolder[] = old.concat(result.items.filter((f: MemberFolder) => {
        if (ids.has(f.id)) { return false; } ids.add(f.id); return true;
      }));
      if (collected) { this.collected = all; this.collectedMore = result.hasMore; }
      else { this.created = all; this.createdMore = result.hasMore; }
      this.pages[i]++;
    } catch (e) {
      if (!this.destroyed && generation === this.generations[i]) {
        if (collected) { this.collectedError = (e as Error).message; }
        else { this.createdError = (e as Error).message; }
      }
    } finally {
      if (!this.destroyed && generation === this.generations[i]) {
        if (collected) { this.collectedBusy = false; } else { this.createdBusy = false; }
        this.refreshing = this.collectedBusy || this.createdBusy;
      }
    }
  }
  @Builder
  Header(title: string, open: boolean, collected: boolean) {
    Row({ space: 8 }) {
      Image($r('app.media.icon_arrow_right')).width(18).height(18).rotate({ angle: open ? 90 : 0 })
        .fillColor($r('app.color.text_secondary'))
      Text(title).fontSize(14).fontColor($r('app.color.text_primary'))
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.bg_page')).onClick(() => {
        if (collected) { this.collectedOpen = !this.collectedOpen; } else { this.createdOpen = !this.createdOpen; }
      })
  }
  @Builder
  Tail(collected: boolean) {
    Text((collected ? this.collectedError : this.createdError) || ((collected ? this.collectedBusy : this.createdBusy)
      ? '加载中…' : (collected ? this.collectedMore : this.createdMore) ? '加载更多' : '没有更多公开收藏夹'))
      .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.Center).padding(24)
      .onClick(() => { this.load(collected); })
  }
  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      List({ scroller: this.listScroller }) {
        ListItemGroup({ header: () => { this.Header('创建的收藏夹', this.createdOpen, false); } }) {
          if (this.createdOpen) {
            ForEach(this.created, (f: MemberFolder) => { ListItem() { MemberFolderCard({ model: f }) } },
              (f: MemberFolder) => 'created_' + f.id.toString())
            ListItem() { this.Tail(false) }.onAppear(() => {
              if (this.createdMore && !this.createdError) { this.load(false); }
            })
          }
        }
        ListItemGroup({ header: () => { this.Header('收藏的收藏夹', this.collectedOpen, true); } }) {
          if (this.collectedOpen) {
            ForEach(this.collected, (f: MemberFolder) => { ListItem() { MemberFolderCard({ model: f }) } },
              (f: MemberFolder) => 'collected_' + f.id.toString())
            ListItem() { this.Tail(true) }.onAppear(() => {
              if (this.collectedMore && !this.collectedError) { this.load(true); }
            })
          }
        }
        ListItem() { Column().height(100).width('100%') }
      }.width('100%').height('100%').scrollBar(BarState.Off).sticky(StickyStyle.Header).nestedScroll(MEMBER_NESTED)
        .edgeEffect(EdgeEffect.None, { alwaysEnabled: true })
        .friction(NARA_SCROLL_FRICTION)
    }.width('100%').height('100%').onRefreshing(() => { this.refreshing = true; this.refresh(); })
  }
}
