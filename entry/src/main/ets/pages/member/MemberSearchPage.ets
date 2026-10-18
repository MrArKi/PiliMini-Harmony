import { router, curves } from '@kit.ArkUI';
import { MemberFeed } from '../../components/member/MemberFeed';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
@Entry
@Component
struct MemberSearchPage {
  @State mid: number = 0;
  @State name: string = '';
  @State text: string = '';
  @State query: string = '';
  @State revision: number = -1;
  @State tab: number = 0;
  @State progress: number = 0;
  @State pageWidth: number = 412;
  @State labelWidths: number[] = [28, 28];
  @State videoCount: number = -1;
  @State dynamicCount: number = -1;
  @StorageProp('statusBarHeight') statusH: number = 0;
  private tabs: TabsController = new TabsController();
  private videoScroller: Scroller = new Scroller();
  private dynamicScroller: Scroller = new Scroller();
  aboutToAppear(): void {
    const p = router.getParams() as Record<string, string>;
    this.mid = Number(p['mid'] || 0); this.name = p['name'] || '该UP主';
  }
  private search(): void {
    this.query = this.text.trim();
    if (this.query) { this.videoCount = -1; this.dynamicCount = -1; this.revision++; }
    this.getUIContext().getFocusController().clearFocus();
  }
  private label(index: number): string {
    const count: number = index === 0 ? this.videoCount : this.dynamicCount;
    return (index === 0 ? '视频' : '动态') + (count >= 0 ? ' ' + count.toString() : '');
  }
  private select(index: number): void {
    if (index !== this.tab) { this.tabs.changeIndex(index); return; }
    const scroller: Scroller = index === 0 ? this.videoScroller : this.dynamicScroller;
    scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: {
      duration: NARA_ROUTE_DURATION, curve: curves.cubicBezierCurve(0.35, 0.91, 0.33, 0.97) } });
  }
  private indicatorWidth(): number {
    const p: number = Math.max(0, Math.min(1, this.progress));
    return this.labelWidths[0] * (1 - p) + this.labelWidths[1] * p;
  }
  @Builder
  SearchTabs() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row() {
        ForEach([0, 1], (index: number) => {
          Stack() {
            Text(this.label(index)).fontSize(14).fontColor($r('app.color.text_secondary'))
              .onAreaChange((_old: Area, area: Area) => {
                const widths: number[] = this.labelWidths.slice(); widths[index] = Number(area.width); this.labelWidths = widths;
              })
            Text(this.label(index)).fontSize(14).fontColor($r('app.color.brand_pink'))
              .opacity(Math.max(0, 1 - Math.abs(this.progress - index)))
          }.layoutWeight(1).height(45).onClick(() => { this.select(index); })
            .id('member_search_tab_' + index.toString()).accessibilityText(this.label(index)).accessibilitySelected(this.tab === index)
        }, (index: number) => index.toString())
      }.width('100%')
      Column().height(3).width(this.indicatorWidth()).borderRadius(2).backgroundColor($r('app.color.brand_pink'))
        .translate({ x: this.pageWidth / 4 + Math.max(0, Math.min(1, this.progress)) * this.pageWidth / 2 - this.indicatorWidth() / 2 })
    }.height(45).width('100%').border({ width: { bottom: 0.3 }, color: $r('app.color.divider') })
  }
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
  }
  build() {
    Column() {
      Row({ space: 4 }) {
        Image($r('app.media.icon_arrow_left')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .onClick(() => { router.back(); }).accessibilityText('返回')
        TextInput({ text: this.text, placeholder: '搜索' }).fontSize(16).height(44).defaultFocus(true)
          .layoutWeight(1).backgroundColor(Color.Transparent).fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary')).enterKeyType(EnterKeyType.Search)
          .onChange((v: string) => { this.text = v; if (!v) { this.query = ''; this.revision = -1; } })
          .onSubmit(() => { this.search(); })
          Image($r('app.media.icon_clear')).width(44).height(44).padding(11).fillColor($r('app.color.text_secondary'))
            .accessibilityText('清空').id('member_search_clear')
            .onClick(() => { this.text = ''; this.query = ''; this.revision = -1; })
        Image($r('app.media.icon_search')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .onClick(() => { this.search(); }).accessibilityText('搜索')
      }.width('100%').height(56 + this.statusH).padding({ top: this.statusH, right: 8 })
      if (this.revision >= 0 && this.query) {
        this.SearchTabs()
        Tabs({ index: this.tab, controller: this.tabs }) {
          TabContent() { MemberFeed({ mid: this.mid, kind: 'video', keyword: this.query, queryRevision: this.revision, listScroller: this.videoScroller,
            onTotal: (count: number) => { this.videoCount = count; } }) }
          TabContent() { MemberFeed({ mid: this.mid, kind: 'dynamic', keyword: this.query, queryRevision: this.revision, listScroller: this.dynamicScroller,
            onTotal: (count: number) => { this.dynamicCount = count; } }) }
        }.barHeight(0).width('100%').layoutWeight(1).animationDuration(300).onChange((i: number) => { this.tab = i; })
          .onContentDidScroll((_s: number, index: number, position: number) => { this.progress = index - position; })
          .onAnimationEnd((index: number) => { this.progress = index; })
      } else {
        Column() {
          Blank().layoutWeight(1)
          Text('搜索「' + this.name + '」的动态、视频').fontSize(14).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Center)
          Blank().layoutWeight(3)
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
      .onAreaChange((_old: Area, area: Area) => { this.pageWidth = Number(area.width); })
  }
}
