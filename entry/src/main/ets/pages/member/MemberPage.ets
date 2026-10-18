import { router, promptAction, display, curves } from '@kit.ArkUI';
import { MemberService, MemberProfile, MemberRelation } from '../../service/member_service';
import { AuthService } from '../../service/auth_service';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { GalleryThumbnail, nextGalleryId } from '../../components/GalleryThumbnail';
import { MemberFeed } from '../../components/member/MemberFeed';
import { MemberOverview } from '../../components/member/MemberOverview';
import { MemberFavorites } from '../../components/member/MemberFavorites';
import { MemberLevel } from '../../components/member/MemberLevel';
import { formatPlayCount } from '../../components/VideoCard';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE, NARA_SCROLL_FRICTION } from '../../common/nara_motion';

@Entry
@Component
struct MemberPage {
  @State mid: number = 0;
  @State profile: MemberProfile | undefined = undefined;
  @State error: string = '';
  @State loading: boolean = true;
  @State tab: number = 0;
  @State progress: number = 0;
  @State sub: number = 0;
  @State pageHeight: number = 800;
  @State pageWidth: number = 412;
  @State headerHeight: number = 350;
  @State collapsed: number = 0;
  @State relation: number = 0;
  @State relationKnown: boolean = false;
  @State relationBusy: boolean = false;
  @State own: boolean = false;
  @StorageProp('statusBarHeight') statusH: number = 0;
  private tabs: TabsController = new TabsController();
  private subTabs: TabsController = new TabsController();
  private outer: Scroller = new Scroller();
  private overviewScroller: Scroller = new Scroller();
  private dynamicScroller: Scroller = new Scroller();
  private videoScroller: Scroller = new Scroller();
  private opusScroller: Scroller = new Scroller();
  private collectionScroller: Scroller = new Scroller();
  private favoriteScroller: Scroller = new Scroller();
  private gallery: string = nextGalleryId();
  private destroyed: boolean = false;
  private generation: number = 0;
  private relationGeneration: number = 0;
  private dialogBusy: boolean = false;
  aboutToAppear(): void {
    this.destroyed = false;
    const p = router.getParams() as Record<string, string>;
    this.mid = Number(p['mid'] || 0);
    try { const d = display.getDefaultDisplaySync(); this.pageHeight = px2vp(d.height); this.pageWidth = px2vp(d.width); } catch (_) {}
    if (this.mid > 0) { this.load(); } else { this.error = '用户ID无效'; this.loading = false; }
  }
  onPageShow(): void { if (this.mid > 0) { this.loadRelation(); } }
  aboutToDisappear(): void { this.destroyed = true; this.generation++; this.relationGeneration++; }
  private async load(): Promise<void> {
    const version: number = ++this.generation; this.loading = true; this.error = '';
    try {
      const result: MemberProfile = await MemberService.profile(this.mid);
      if (!this.destroyed && version === this.generation) { this.profile = result; }
    } catch (e) { if (!this.destroyed && version === this.generation) { this.error = (e as Error).message; } }
    finally { if (!this.destroyed && version === this.generation) { this.loading = false; } }
  }
  private blocked(): boolean { return this.relation === 128; }
  private followed(): boolean { return this.relation === 1 || this.relation === 2 || this.relation === 6; }
  private async loadRelation(): Promise<void> {
    const version: number = ++this.relationGeneration;
    try {
      const uid: string = await CookieStore.get('DedeUserID');
      if (this.destroyed || version !== this.relationGeneration) { return; }
      this.own = Number(uid) === this.mid;
      if (!uid || this.own) { this.relationKnown = false; return; }
      const result: MemberRelation = await MemberService.relation(this.mid);
      if (!this.destroyed && version === this.relationGeneration) {
        this.relation = result.attribute || 0; this.relationKnown = true;
      }
    } catch (_) { if (!this.destroyed && version === this.relationGeneration) { this.relationKnown = false; } }
  }
  private async modify(act: number): Promise<void> {
    if (this.relationBusy || this.own) { return; }
    this.relationBusy = true;
    try {
      if (!await AuthService.isLogin()) {
        if (!this.destroyed) { router.pushUrl({ url: 'pages/login/LoginPage' }); } return;
      }
      if (this.destroyed) { return; }
      await MemberService.modifyRelation(this.mid, act);
      if (!this.destroyed) {
        await this.loadRelation();
        if (!this.destroyed) { promptAction.showToast({ message: act === 5 ? '已拉黑' : act === 6 ? '已解除拉黑' : act === 1 ? '已关注' : '已取消关注' }); }
      }
    } catch (e) { if (!this.destroyed) { promptAction.showToast({ message: (e as Error).message }); } }
    finally { if (!this.destroyed) { this.relationBusy = false; } }
  }
  private async follow(): Promise<void> {
    if (!await AuthService.isLogin()) { if (!this.destroyed) { router.pushUrl({ url: 'pages/login/LoginPage' }); } return; }
    if (this.destroyed) { return; }
    if (!this.relationKnown) { await this.loadRelation(); }
    if (!this.relationKnown || this.destroyed) { if (!this.destroyed) { promptAction.showToast({ message: '关系状态未获取，请重试' }); } return; }
    if (this.blocked()) { await this.confirmBlock(); return; }
    if (this.followed()) {
      if (!await this.confirm('取消关注', '确定不再关注该UP主？')) { return; }
    }
    this.modify(this.followed() ? 2 : 1);
  }
  private async confirmBlock(): Promise<void> {
    if (this.relationBusy || this.own) { return; }
    if (!await AuthService.isLogin()) { if (!this.destroyed) { router.pushUrl({ url: 'pages/login/LoginPage' }); } return; }
    await this.loadRelation();
    if (!this.relationKnown || this.destroyed) { return; }
    const blocked: boolean = this.blocked();
    if (await this.confirm(blocked ? '解除拉黑' : '拉黑用户',
      blocked ? '确定解除对该用户的拉黑？' : '拉黑后将不再关注该用户，并限制与你的互动。确定拉黑？')) {
      this.modify(blocked ? 6 : 5);
    }
  }
  private async confirm(title: string, message: string): Promise<boolean> {
    if (this.dialogBusy || this.destroyed) { return false; }
    this.dialogBusy = true;
    try {
      const result = await promptAction.showDialog({ title: title, message: message,
        buttons: [{ text: '取消', color: '#888888' }, { text: '确定', color: '#FB7299' }] });
      return !this.destroyed && result.index === 1;
    } catch (_) { return false; }
    finally { this.dialogBusy = false; }
  }
  private async more(): Promise<void> {
    if (this.own) { return; }
    try {
      const result = await promptAction.showActionMenu({ title: '更多',
        buttons: [{ text: this.blocked() ? '解除拉黑' : '拉黑', color: '#FB7299' }] });
      if (result.index === 0 && !this.destroyed) { await this.confirmBlock(); }
    } catch (_) { /* 取消菜单 */ }
  }
  private select(index: number): void {
    if (index === this.tab) {
      const scroller: Scroller = index === 0 ? this.overviewScroller : index === 1 ? this.dynamicScroller
        : index === 3 ? this.favoriteScroller : this.sub === 0 ? this.videoScroller
        : this.sub === 1 ? this.opusScroller : this.collectionScroller;
      scroller.scrollTo({ xOffset: 0, yOffset: 0,
        animation: { duration: NARA_ROUTE_DURATION, curve: curves.cubicBezierCurve(0.35, 0.91, 0.33, 0.97) } });
      this.outer.scrollTo({ xOffset: 0, yOffset: 0,
        animation: { duration: NARA_ROUTE_DURATION, curve: curves.cubicBezierCurve(0.35, 0.91, 0.33, 0.97) } });
    } else { this.tabs.changeIndex(index); }
  }
  private moreSection(tab: number, sub: number): void {
    this.sub = sub; this.subTabs.changeIndex(sub); this.tabs.changeIndex(tab);
  }
  @Builder
  Stat(value: number, label: string) {
    Column({ space: 3 }) {
      Text(formatPlayCount(value)).fontSize(14).fontColor($r('app.color.text_primary'))
      Text(label).fontSize(12).fontColor($r('app.color.text_secondary'))
    }.layoutWeight(1)
  }
  @Builder
  Header(p: MemberProfile) {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          if (p.banner) { GalleryThumbnail({ urls: [p.banner], groupId: this.gallery + '_bg', w: 960, h: 360 }) }
        }.width('100%').height(135 + this.statusH).backgroundColor($r('app.color.btn_soft_bg'))
        Column() {
          GalleryThumbnail({ urls: [p.face], groupId: this.gallery + '_face', w: 240, h: 240 })
        }.width(80).height(80).borderRadius(40).clip(true).position({ x: 20, y: 115 + this.statusH })
        Column({ space: 7 }) {
          Row() { this.Stat(p.followers, '粉丝'); this.Stat(p.following, '关注'); this.Stat(p.likes, '获赞') }.width('100%')
          if (!this.own) {
            Button(this.blocked() ? '已拉黑' : this.followed() ? '已关注' : '关注')
              .height(30).width('100%').fontSize(13).borderRadius(15)
              .backgroundColor(this.blocked() || this.followed() ? $r('app.color.btn_soft_bg') : $r('app.color.member_secondary_container'))
              .fontColor(this.blocked() || this.followed() ? $r('app.color.text_secondary') : $r('app.color.member_on_secondary_container'))
              .enabled(!this.relationBusy).onClick(() => { this.follow().catch((e: Error) => {
                if (!this.destroyed) { promptAction.showToast({ message: e.message || '操作失败，请重试' }); }
              }); })
          }
        }.width(Math.max(160, this.pageWidth - 175)).position({ x: 160, y: 140 + this.statusH })
      }.width('100%').height(222 + this.statusH)
      Row({ space: 8 }) {
        Text(p.name).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(p.vip ? $r('app.color.brand_pink') : $r('app.color.text_primary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '75%' })
        MemberLevel({ level: p.level })
      }.width('100%').padding({ left: 20, right: 20 })
      if (p.official) {
        Text(p.official).fontSize(14).fontColor($r('app.color.text_primary')).width('100%')
          .padding({ left: 20, right: 20, top: 6 })
      }
      if (p.sign) {
        Text(p.sign).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          .padding({ left: 20, right: 20, top: 6 })
      }
      Text('UID ' + p.mid.toString()).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
        .padding({ left: 20, right: 20, top: 6, bottom: 12 })
    }.width('100%').alignItems(HorizontalAlign.Start).onAreaChange((_old: Area, area: Area) => {
      this.headerHeight = Number(area.height);
    })
  }
  @Builder
  MainTabs() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row() {
        ForEach(['主页', '动态', '投稿', '收藏'], (name: string, i: number) => {
          Stack() {
            Text(name).fontSize(14).fontColor($r('app.color.text_secondary'))
            Text(name).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.brand_pink'))
              .opacity(Math.max(0, 1 - Math.abs(this.progress - i)))
          }.layoutWeight(1).height(45).onClick(() => { this.select(i); })
            .id('member_tab_' + i.toString())
            .accessibilityText(name).accessibilitySelected(this.tab === i)
        }, (s: string) => s)
      }.width('100%')
      Column().width(28).height(3).borderRadius(2).backgroundColor($r('app.color.brand_pink'))
        .translate({ x: (this.pageWidth / 4 - 28) / 2 + this.progress * this.pageWidth / 4 })
    }.width('100%').height(45).border({ width: { bottom: 0.3 }, color: $r('app.color.divider') })
      .backgroundColor($r('app.color.bg_page'))
  }
  @Builder
  Contribute() {
    Column() {
      Row({ space: 3 }) {
        ForEach(['视频', '图文', '合集和列表'], (name: string, i: number) => {
          Text(name).fontSize(14).fontColor(this.sub === i ? $r('app.color.member_on_secondary_container') : $r('app.color.text_secondary'))
            .padding({ left: 14, right: 14, top: 6, bottom: 6 }).borderRadius(20)
            .backgroundColor(this.sub === i ? $r('app.color.member_secondary_container') : Color.Transparent)
            .onClick(() => { this.subTabs.changeIndex(i); })
            .id('member_sub_' + i.toString())
        }, (s: string) => s)
        Blank()
      }.width('100%').height(45).padding({ left: 8, right: 8 })
      Tabs({ index: this.sub, controller: this.subTabs }) {
        TabContent() { MemberFeed({ mid: this.mid, kind: 'video', listScroller: this.videoScroller }) }
        TabContent() { MemberFeed({ mid: this.mid, kind: 'opus', listScroller: this.opusScroller }) }
        TabContent() { MemberFeed({ mid: this.mid, kind: 'collections', listScroller: this.collectionScroller }) }
      }.barHeight(0).scrollable(false).animationDuration(0).width('100%').layoutWeight(1)
        .onChange((i: number) => { this.sub = i; })
    }.width('100%').height('100%')
  }
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.profile) {
        Scroll(this.outer) {
          Column() {
            this.Header(this.profile)
            Column() {
              this.MainTabs()
              Tabs({ index: this.tab, controller: this.tabs }) {
                TabContent() { MemberOverview({ mid: this.mid, listScroller: this.overviewScroller, onMore: (tab: number, sub: number) => { this.moreSection(tab, sub); } }) }
                TabContent() { MemberFeed({ mid: this.mid, kind: 'dynamic', listScroller: this.dynamicScroller }) }
                TabContent() { this.Contribute() }
                TabContent() { MemberFavorites({ mid: this.mid, listScroller: this.favoriteScroller }) }
              }.barHeight(0).animationDuration(300).width('100%').layoutWeight(1)
                .onChange((i: number) => { this.tab = i; })
                .onContentDidScroll((_s: number, index: number, position: number) => { this.progress = index - position; })
                .onAnimationEnd((i: number) => { this.progress = i; })
            }.width('100%').height(Math.max(240, this.pageHeight - this.statusH - 56))
          }.width('100%')
        }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
          .friction(NARA_SCROLL_FRICTION)
          .onDidScroll(() => { this.collapsed = Math.min(1, this.outer.currentOffset().yOffset / Math.max(1, this.headerHeight - this.statusH - 56)); })
      } else {
        Column({ space: 16 }) {
          if (this.loading) { LoadingProgress().width(36).height(36) }
          else {
            Text(this.error).fontSize(14).fontColor($r('app.color.text_secondary'))
            Button('重试').onClick(() => { this.load(); })
          }
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }
      Stack() {
        Column().width('100%').height('100%').backgroundColor($r('app.color.bg_page')).opacity(this.collapsed)
        Row({ space: 8 }) {
          Image($r('app.media.icon_arrow_left')).width(24).height(24).fillColor($r('app.color.text_primary'))
            .padding(10).width(44).height(44).onClick(() => { router.back(); }).accessibilityText('返回').id('member_back')
          Text(this.profile?.name || 'UP主空间').fontSize(18).fontColor($r('app.color.text_primary'))
            .maxLines(1).opacity(this.collapsed).layoutWeight(1)
          Image($r('app.media.icon_search')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
            .id('member_search')
            .accessibilityText('空间搜索').onClick(() => { router.pushUrl({ url: 'pages/member/MemberSearchPage',
              params: { 'mid': this.mid.toString(), 'name': this.profile?.name || '' } }); })
          if (!this.own) {
            Image($r('app.media.icon_more')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
              .id('member_more')
              .accessibilityText('更多').onClick(() => { this.more(); })
          }
        }.width('100%').padding({ left: 4, right: 4, top: this.statusH }).height(56 + this.statusH)
      }.width('100%').height(56 + this.statusH)
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
      .onAreaChange((_old: Area, area: Area) => { this.pageHeight = Number(area.height); this.pageWidth = Number(area.width); })
  }
}
