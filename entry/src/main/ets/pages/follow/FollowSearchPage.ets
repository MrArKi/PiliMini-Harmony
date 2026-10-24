/** 关注内服务端搜索：Nara CommonSearchPage + FollowItem（不显示关系按钮）。 */
import { router } from '@kit.ArkUI';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { BasicDataSource } from '../../common/list_data_source';
import { FollowItemView } from '../../components/follow/FollowItemView';
import { LoadingFooter, ErrorRetry } from '../../components/StateViews';
import { FollowItem, FollowPage, FollowSession } from '../../model/follow';
import { FollowService } from '../../service/follow_service';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { FollowChanged, onFollowChanged } from '../../infra/event/app_events';

@Entry
@Component
struct FollowSearchPage {
  @State keyword: string = '';
  @State submitted: string = '';
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State rangeHint: string = '';
  @State resultCount: number = 0;
  @State hasMore: boolean = false;
  @State manualMore: boolean = false;
  @State needLogin: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private input: TextInputController = new TextInputController();
  private scroller: Scroller = new Scroller();
  private ds: BasicDataSource<FollowItem> = new BasicDataSource<FollowItem>();
  private items: FollowItem[] = [];
  private seen: Set<number> = new Set<number>();
  private excluded: Set<number> = new Set<number>();
  private session: FollowSession | undefined = undefined;
  private nextPage: number = 1;
  private rawCount: number = 0;
  private queryRevision: number = -1;
  private generation: number = 0;
  private destroyed: boolean = false;
  private initialFocusRequested: boolean = false;
  private focusTimer: number = -1;
  private offFollow: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.offFollow = onFollowChanged((change: FollowChanged): void => {
      if (this.destroyed || !this.session || change.revision !== this.session.revision
        || change.revision !== CookieStore.sessionRevision() || change.followed) { return; }
      this.excluded.add(change.mid);
      const filtered: FollowItem[] = this.items.filter((item: FollowItem) => item.mid !== change.mid);
      if (filtered.length === this.items.length) { return; }
      this.items = filtered;
      this.resultCount = filtered.length;
      this.ds.reload(filtered);
    });
  }

  onPageShow(): void {
    if (this.queryRevision >= 0 && this.queryRevision !== CookieStore.sessionRevision()) {
      this.clear(false);
      this.session = undefined;
      this.needLogin = false;
    }
    if (!this.initialFocusRequested) {
      this.initialFocusRequested = true;
      this.requestInputFocus();
    }
  }

  onPageHide(): void { this.cancelFocus(); }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.generation++;
    this.cancelFocus();
    if (this.offFollow) { this.offFollow(); this.offFollow = undefined; }
  }

  private cancelFocus(): void {
    if (this.focusTimer >= 0) { clearTimeout(this.focusTimer); this.focusTimer = -1; }
  }

  private requestInputFocus(): void {
    this.cancelFocus();
    this.focusTimer = setTimeout(() => {
      this.focusTimer = -1;
      if (!this.destroyed) { this.getUIContext().getFocusController().requestFocus('follow_search_input'); }
    }, NARA_ROUTE_DURATION + 32);
  }

  private resetResults(): void {
    this.generation++;
    this.loading = false; this.loadingMore = false;
    this.error = ''; this.rangeHint = ''; this.needLogin = false;
    this.items = []; this.seen.clear(); this.excluded.clear(); this.ds.reload([]);
    this.resultCount = 0; this.rawCount = 0;
    this.nextPage = 1; this.hasMore = false; this.manualMore = false;
  }

  private clear(focus: boolean = true): void {
    this.keyword = ''; this.submitted = '';
    this.resetResults();
    if (focus) { this.requestInputFocus(); }
  }

  private clearInput(): void {
    if (this.keyword.length === 0) {
      this.cancelFocus(); this.input.stopEditing(); this.clear(false); router.back(); return;
    }
    this.clear();
  }

  private changeKeyword(value: string): void {
    this.keyword = value; this.cancelFocus();
    if (this.submitted && value.trim() !== this.submitted) {
      this.submitted = ''; this.resetResults();
    }
  }

  private current(generation: number, revision: number): boolean {
    return !this.destroyed && generation === this.generation && revision === CookieStore.sessionRevision();
  }

  private async search(): Promise<void> {
    const query: string = this.keyword.trim();
    if (this.destroyed) { return; }
    if (!query) { this.clear(); return; }
    if ((this.loading || this.loadingMore) && this.submitted === query
      && this.queryRevision === CookieStore.sessionRevision()) { return; }
    this.cancelFocus(); this.input.stopEditing();
    this.keyword = query; this.submitted = query;
    this.resetResults();
    this.loading = true;
    const generation: number = this.generation;
    const revision: number = CookieStore.sessionRevision();
    this.queryRevision = revision;
    try {
      const session: FollowSession = await FollowService.captureSession(revision);
      if (!this.current(generation, revision)) { return; }
      this.session = session;
      const page: FollowPage = await FollowService.search(session, query, 1);
      if (!this.current(generation, revision)) { return; }
      this.applyPage(page, true);
      try { this.scroller.scrollTo({ xOffset: 0, yOffset: 0 }); } catch (_) {}
    } catch (e) {
      if (this.current(generation, revision)) {
        this.error = (e as Error).message || '搜索失败，请重试';
        this.needLogin = this.error.indexOf('登录') >= 0;
      }
    } finally { if (this.current(generation, revision)) { this.loading = false; } }
  }

  private applyPage(page: FollowPage, first: boolean): void {
    const appended: FollowItem[] = [];
    for (let i: number = 0; i < page.items.length; i++) {
      const item: FollowItem = page.items[i];
      if (!this.seen.has(item.mid)) {
        this.seen.add(item.mid);
        if (!this.excluded.has(item.mid)) { appended.push(item); }
      }
    }
    this.rawCount += page.items.length;
    this.nextPage = page.nextPage;
    this.hasMore = page.hasMore;
    if (first) { this.items = appended; this.ds.reload(appended); }
    else { this.items = this.items.concat(appended); this.ds.append(appended); }
    this.resultCount = this.items.length;
    this.rangeHint = '';
    this.manualMore = page.hasMore && appended.length === 0;
    if (this.manualMore) {
      this.rangeHint = '本页未返回新的有效关注，可手动继续加载';
    } else if (!page.hasMore && page.total >= 0 && this.rawCount < page.total) {
      this.rangeHint = '接口报告共' + page.total.toString() + '项，已显示当前可获取范围';
    }
  }

  private async loadMore(manual: boolean = false): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMore || !this.session || !this.submitted
      || (this.manualMore && !manual)) { return; }
    const generation: number = this.generation;
    const session: FollowSession = this.session;
    if (!this.current(generation, session.revision)) { return; }
    this.loadingMore = true; this.error = '';
    try {
      const page: FollowPage = await FollowService.search(session, this.submitted, this.nextPage);
      if (this.current(generation, session.revision)) { this.applyPage(page, false); }
    } catch (e) {
      if (this.current(generation, session.revision)) { this.error = (e as Error).message || '加载失败，点击重试'; }
    } finally { if (this.current(generation, session.revision)) { this.loadingMore = false; } }
  }

  @Builder
  SearchBar() {
    Row({ space: 2 }) {
      Image($r('app.media.icon_arrow_left')).width(44).height(44).padding(11)
        .fillColor($r('app.color.text_primary')).accessibilityText('返回')
        .onClick(() => { router.back(); })
      TextInput({ text: this.keyword, placeholder: '搜索', controller: this.input })
        .id('follow_search_input').defaultFocus(true).enableKeyboardOnFocus(true)
        .enterKeyType(EnterKeyType.Search).height(44).layoutWeight(1).fontSize(16)
        .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
        .backgroundColor(Color.Transparent).padding(0)
        .onChange((value: string) => { this.changeKeyword(value); })
        .onSubmit(() => { this.search(); })
      Image($r('app.media.icon_clear')).width(44).height(44).padding(11)
        .fillColor($r('app.color.text_secondary')).accessibilityText('清空').id('follow_search_clear')
        .onClick(() => { this.clearInput(); })
      Image($r('app.media.icon_search')).width(44).height(44).padding(11)
        .fillColor($r('app.color.text_primary')).accessibilityText('搜索').id('follow_search_submit')
        .onClick(() => { this.search(); })
    }.width('100%').height(56 + this.statusBarH).padding({ top: this.statusBarH, right: 10 })
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
  }

  build() {
    Column() {
      this.SearchBar()
      if (!this.submitted) {
        Column() {
          Text('搜索我的关注').fontSize(14).fontColor($r('app.color.text_secondary'))
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.loading) {
        Column() { LoadingFooter({ text: '正在搜索…' }) }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.error && this.resultCount === 0) {
        Column() {
          ErrorRetry({ text: this.error, onRetry: () => { if (this.hasMore) { this.loadMore(true); } else { this.search(); } } })
          if (this.needLogin) {
            Button('去登录').onClick(() => { router.pushUrl({ url: 'pages/login/LoginPage' }); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.resultCount === 0) {
        Column({ space: 12 }) {
          Text(this.hasMore ? '当前页没有可显示的关注' : '没有找到相关关注').fontSize(14).fontColor($r('app.color.text_secondary'))
          if (this.rangeHint) {
            Text(this.rangeHint).fontSize(12).fontColor($r('app.color.text_secondary'))
          }
          if (this.hasMore) {
            Button(this.loadingMore ? '加载中…' : '继续加载下一页').fontSize(13).enabled(!this.loadingMore)
              .onClick(() => { this.loadMore(true); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.scroller }) {
          LazyForEach(this.ds, (item: FollowItem) => {
            ListItem() { FollowItemView({ item: item }) }.width('100%')
          }, (item: FollowItem) => item.mid.toString())
          ListItem() {
            Column() {
              if (this.error) {
                Text(this.error).fontSize(12).fontColor($r('app.color.brand_pink'))
                  .padding(18).onClick(() => { this.loadMore(true); })
              } else if (this.loadingMore) { LoadingFooter({ text: '加载中…' }) }
              else if (this.rangeHint) {
                Text(this.rangeHint).fontSize(12).fontColor($r('app.color.text_secondary')).padding(18)
                if (this.hasMore) {
                  Button('继续加载下一页').fontSize(13).enabled(!this.loadingMore).onClick(() => { this.loadMore(true); })
                }
              } else if (!this.hasMore) {
                Text('没有更多了').fontSize(12).fontColor($r('app.color.text_secondary')).padding(18)
              }
            }.width('100%').padding({ bottom: 100 + this.navBarH })
          }
        }.width('100%').layoutWeight(1).cachedCount(3).id('follow_search_results')
          .onReachEnd(() => { if (!this.error) { this.loadMore(); } })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
