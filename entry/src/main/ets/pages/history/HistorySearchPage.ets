/** Nara CommonSearchPage + HistorySearch：服务端分页，不缓存私人查询（spec-29）。 */
import { router } from '@kit.ArkUI';
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { BasicDataSource } from '../../common/list_data_source';
import { HistoryRow } from '../../components/history/HistoryRow';
import { EmptyState, ErrorRetry, LoadingFooter } from '../../components/StateViews';
import { HistoryService, HistoryItem, HistorySearchResult, HistorySession } from '../../service/history_service';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { onAuthLogout } from '../../infra/event/app_events';

@Entry
@Component
struct HistorySearchPage {
  @State keyword: string = '';
  @State submitted: string = '';
  @State itemCount: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State firstLoaded: boolean = false;
  @State needLogin: boolean = false;
  @State noMore: boolean = false;
  @State error: string = '';
  @State moreError: string = '';
  @State accountError: string = '';
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private ds: BasicDataSource<HistoryItem> = new BasicDataSource<HistoryItem>();
  private scroller: Scroller = new Scroller();
  private input: TextInputController = new TextInputController();
  private keys: Set<string> = new Set<string>();
  private session: HistorySession | undefined = undefined;
  private revision: number = -1;
  private nextPage: number = 1;
  private autoLoadMore: boolean = false;
  private request: number = 0;
  private destroyed: boolean = false;
  private visible: boolean = false;
  private initialFocusRequested: boolean = false;
  private focusTimer: number = -1;
  private offLogout: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.offLogout = onAuthLogout((): void => {
      this.resetAccount(); this.needLogin = true; this.input.stopEditing();
    });
  }

  onPageShow(): void {
    this.visible = true;
    if (this.revision !== CookieStore.sessionRevision() || this.session === undefined) { this.syncAccount(); }
    if (!this.initialFocusRequested) {
      this.initialFocusRequested = true;
      this.focusTimer = setTimeout(() => {
        this.focusTimer = -1;
        if (!this.destroyed && this.visible && this.submitted.length === 0 && !this.needLogin) { this.focusInput(); }
      }, NARA_ROUTE_DURATION + 32);
    }
  }

  onPageHide(): void { this.visible = false; this.cancelFocus(); }

  aboutToDisappear(): void {
    this.destroyed = true; this.request++; this.cancelFocus(); this.session = undefined;
    if (this.offLogout !== undefined) { this.offLogout(); this.offLogout = undefined; }
  }

  private cancelFocus(): void {
    if (this.focusTimer >= 0) { clearTimeout(this.focusTimer); this.focusTimer = -1; }
  }

  private focusInput(): void { this.getUIContext().getFocusController().requestFocus('history_search_input'); }

  private resetQuery(): void {
    this.request++;
    this.submitted = ''; this.ds.reload([]); this.keys.clear(); this.itemCount = 0;
    this.nextPage = 1; this.autoLoadMore = false; this.firstLoaded = false; this.noMore = false;
    this.loading = false; this.loadingMore = false; this.error = ''; this.moreError = '';
  }

  private resetAccount(): void {
    this.resetQuery(); this.keyword = ''; this.session = undefined;
    this.accountError = ''; this.needLogin = false;
    this.revision = CookieStore.sessionRevision();
  }

  private current(request: number, revision: number): boolean {
    if (this.destroyed || request !== this.request) { return false; }
    if (revision !== CookieStore.sessionRevision()) {
      this.resetAccount();
      if (this.visible) { this.syncAccount(); }
      return false;
    }
    return true;
  }

  private async syncAccount(): Promise<void> {
    if (this.revision !== CookieStore.sessionRevision()) { this.resetAccount(); }
    const revision: number = CookieStore.sessionRevision();
    const request: number = ++this.request;
    this.revision = revision;
    this.accountError = '';
    try {
      const session: HistorySession = await HistoryService.captureSession(revision);
      if (!this.current(request, revision)) { return; }
      this.session = session; this.needLogin = !session.logged;
    } catch (e) {
      if (!this.current(request, revision)) { return; }
      this.accountError = '读取登录状态失败，请重试';
    }
  }

  private clearInput(): void {
    this.cancelFocus();
    if (this.keyword.length === 0) {
      this.input.stopEditing(); this.resetQuery(); router.back(); return;
    }
    this.keyword = ''; this.resetQuery(); this.focusInput();
  }

  private changeKeyword(value: string): void {
    this.keyword = value; this.cancelFocus();
    if (this.submitted.length > 0 && value.trim() !== this.submitted) { this.resetQuery(); }
  }

  private append(items: HistoryItem[]): void {
    const added: HistoryItem[] = [];
    for (let i: number = 0; i < items.length; i++) {
      if (!this.keys.has(items[i].key)) { this.keys.add(items[i].key); added.push(items[i]); }
    }
    this.ds.append(added); this.itemCount = this.ds.size(); this.autoLoadMore = added.length > 0;
  }

  private async search(keyword: string): Promise<void> {
    const query: string = keyword.trim();
    if (query.length === 0 || this.destroyed) { return; }
    if ((this.loading || this.loadingMore) && this.submitted === query &&
      this.revision === CookieStore.sessionRevision()) { return; }
    if (this.revision !== CookieStore.sessionRevision()) { this.resetAccount(); this.syncAccount(); return; }
    this.cancelFocus(); this.input.stopEditing(); this.resetQuery();
    this.accountError = '';
    this.keyword = query; this.submitted = query; this.loading = true;
    const request: number = this.request;
    const revision: number = this.revision;
    try {
      const session: HistorySession = await HistoryService.captureSession(revision);
      if (!this.current(request, revision)) { return; }
      this.session = session; this.needLogin = !session.logged;
      if (!session.logged) { this.loading = false; return; }
      const result: HistorySearchResult = await HistoryService.search(query, 1, session);
      if (!this.current(request, revision)) { return; }
      this.append(result.items); this.nextPage = result.nextPage;
      this.noMore = !result.hasMore; this.firstLoaded = true;
    } catch (e) {
      if (!this.current(request, revision)) { return; }
      this.error = (e as Error).message || '搜索失败，请重试';
    }
    if (this.current(request, revision)) { this.loading = false; }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.noMore || !this.firstLoaded || this.session === undefined) { return; }
    const session: HistorySession = this.session;
    const request: number = this.request;
    const query: string = this.submitted;
    if (!this.current(request, session.revision)) { return; }
    this.loadingMore = true; this.moreError = ''; this.autoLoadMore = false;
    try {
      const result: HistorySearchResult = await HistoryService.search(query, this.nextPage, session);
      if (!this.current(request, session.revision)) { return; }
      this.append(result.items); this.nextPage = result.nextPage; this.noMore = !result.hasMore;
    } catch (e) {
      if (!this.current(request, session.revision)) { return; }
      this.moreError = '加载失败，点击重试';
    }
    if (this.current(request, session.revision)) { this.loadingMore = false; }
  }

  private openVideo(item: HistoryItem): void {
    this.input.stopEditing();
    router.pushUrl({ url: 'pages/video/VideoDetailPage', params: {
      'bvid': item.bvid, 'cid': item.cid.toString(), 'title': item.title
    } });
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
        TextInput({ text: this.keyword, placeholder: '搜索', controller: this.input })
          .id('history_search_input').defaultFocus(true).enableKeyboardOnFocus(true).enterKeyType(EnterKeyType.Search)
          .height(44).layoutWeight(1).fontSize(16).fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary')).backgroundColor(Color.Transparent).padding(0)
          .onChange((value: string) => { this.changeKeyword(value); })
          .onSubmit(() => { this.search(this.keyword); })
        Image($r('app.media.icon_clear')).width(44).height(44).padding(11).fillColor($r('app.color.text_secondary'))
          .onClick(() => { this.clearInput(); }).id('history_search_clear').accessibilityText('清空')
        Image($r('app.media.icon_search')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .onClick(() => { this.search(this.keyword); }).id('history_search_submit').accessibilityText('搜索')
      }.width('100%').height(56 + this.statusBarH).padding({ top: this.statusBarH, right: 10 })
      if (this.accountError.length > 0) {
        Column() { ErrorRetry({ text: this.accountError, onRetry: () => { this.syncAccount(); } }) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.needLogin) {
        Column({ space: 12 }) {
          Text('登录后可搜索观看记录').fontSize(14).fontColor($r('app.color.text_secondary'))
          Button('去登录').fontSize(13).backgroundColor($r('app.color.brand_pink'))
            .onClick(() => { this.input.stopEditing(); router.pushUrl({ url: 'pages/login/LoginPage' }); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.loading) {
        Column() { LoadingFooter({ text: '搜索中…' }) }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column() { ErrorRetry({ text: this.error, onRetry: () => { this.search(this.submitted); } }) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.submitted.length === 0) {
        Column().layoutWeight(1).width('100%')
      } else {
        List({ space: 2, scroller: this.scroller }) {
          ListItem() {
            Text('当前仅展示视频观看记录').fontSize(12).fontColor($r('app.color.text_secondary'))
              .width('100%').textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
          }
          if (this.itemCount === 0) {
            ListItem() {
              EmptyState({ text: this.noMore ? '未找到相关视频观看记录' : '本页暂无视频记录，可继续加载' })
            }
          }
          LazyForEach(this.ds, (item: HistoryItem) => {
            ListItem() { HistoryRow({ item: item, onOpen: (used: HistoryItem) => { this.openVideo(used); } }) }
          }, (item: HistoryItem) => item.key)
          ListItem() {
            Column() {
              if (this.loadingMore) { LoadingFooter() }
              else {
                Text(this.moreError.length > 0 ? this.moreError : (this.noMore ? '没有更多了' : '继续加载'))
                  .fontSize(12).fontColor($r('app.color.text_secondary')).padding(16)
                  .onClick(() => { this.loadMore(); })
              }
            }.width('100%').height(100 + this.navBarH).justifyContent(FlexAlign.Center)
          }
        }.width('100%').layoutWeight(1).cachedCount(3).scrollBar(BarState.Off).padding({ top: 7 })
          .onReachEnd(() => { if (this.autoLoadMore && this.moreError.length === 0) { this.loadMore(); } })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
