/** 观看记录：Nara横卡、游标分页与独立服务端搜索入口（spec-29）。 */
import { NARA_ROUTE_DURATION, NARA_ROUTE_CURVE } from '../../common/nara_motion';
import { router } from '@kit.ArkUI';
import { BasicDataSource } from '../../common/list_data_source';
import { HistoryRow } from '../../components/history/HistoryRow';
import { EmptyState, LoadingFooter, ErrorRetry } from '../../components/StateViews';
import { HistoryService, HistoryItem, HistoryPage, HistorySession } from '../../service/history_service';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { onHistoryChanged, onAuthLogout } from '../../infra/event/app_events';

@Entry
@Component
struct HistoryListPage {
  @State itemCount: number = 0;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State moreError: string = '';
  @State needLogin: boolean = false;
  @State noMore: boolean = false;
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  @StorageProp('navBarHeight') navBarH: number = 0;
  private ds: BasicDataSource<HistoryItem> = new BasicDataSource<HistoryItem>();
  private scroller: Scroller = new Scroller();
  private keys: Set<string> = new Set<string>();
  private session: HistorySession | undefined = undefined;
  private revision: number = -1;
  private firstLoaded: boolean = false;
  private autoLoadMore: boolean = false;
  private nextMax: number = 0;
  private nextViewAt: number = 0;
  private destroyed: boolean = false;
  private visible: boolean = false;
  private dirty: boolean = false;
  private searchChild: boolean = false;
  private request: number = 0;
  private offHistory: (() => void) | undefined = undefined;
  private offLogout: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.offHistory = onHistoryChanged((): void => {
      if (this.visible) { this.reload(true); } else { this.dirty = true; }
    });
    this.offLogout = onAuthLogout((): void => { this.clearAccount(); this.needLogin = true; });
  }

  onPageShow(): void {
    this.visible = true;
    const returningSearch: boolean = this.searchChild;
    this.searchChild = false;
    if (this.revision !== CookieStore.sessionRevision()) { this.clearAccount(); this.reload(); }
    else if (!this.firstLoaded) { this.reload(); }
    else if (this.dirty && !returningSearch) { this.reload(true); }
  }

  onPageHide(): void {
    this.visible = false;
    // 搜索作为子路由覆盖时，迟到刷新/分页不能替换底页与它的滚动锚点。
    if (this.loading || this.refreshing || this.loadingMore) { this.dirty = true; }
    this.request++;
    this.loading = false; this.refreshing = false; this.loadingMore = false;
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.request++;
    this.session = undefined;
    if (this.offHistory !== undefined) { this.offHistory(); this.offHistory = undefined; }
    if (this.offLogout !== undefined) { this.offLogout(); this.offLogout = undefined; }
  }

  private clearAccount(): void {
    this.request++;
    this.revision = CookieStore.sessionRevision();
    this.session = undefined;
    this.ds.reload([]); this.keys.clear(); this.itemCount = 0;
    this.firstLoaded = false; this.autoLoadMore = false; this.nextMax = 0; this.nextViewAt = 0;
    this.loading = false; this.refreshing = false; this.loadingMore = false;
    this.error = ''; this.moreError = ''; this.noMore = false; this.dirty = false;
  }

  private current(request: number, revision: number): boolean {
    if (this.destroyed || request !== this.request) { return false; }
    if (revision !== CookieStore.sessionRevision()) {
      this.clearAccount();
      if (this.visible) { this.reload(); }
      return false;
    }
    return true;
  }

  private replace(items: HistoryItem[]): void {
    this.keys.clear();
    for (let i: number = 0; i < items.length; i++) { this.keys.add(items[i].key); }
    this.ds.reload(items); this.itemCount = this.ds.size(); this.autoLoadMore = items.length > 0;
  }

  private append(items: HistoryItem[]): void {
    const added: HistoryItem[] = [];
    for (let i: number = 0; i < items.length; i++) {
      if (!this.keys.has(items[i].key)) { this.keys.add(items[i].key); added.push(items[i]); }
    }
    this.ds.append(added); this.itemCount = this.ds.size(); this.autoLoadMore = added.length > 0;
  }

  private async reload(silent: boolean = false): Promise<void> {
    if (this.destroyed) { return; }
    const revision: number = CookieStore.sessionRevision();
    if (this.revision !== revision) { this.clearAccount(); }
    this.revision = revision;
    const request: number = ++this.request;
    this.loading = true;
    this.loadingMore = false; this.moreError = ''; this.error = '';
    try {
      const session: HistorySession = await HistoryService.captureSession(revision);
      if (!this.current(request, revision)) { return; }
      this.session = session;
      this.needLogin = !session.logged;
      if (!session.logged) {
        this.replace([]); this.firstLoaded = false; this.loading = false; this.refreshing = false; return;
      }
      const result: HistoryPage = await HistoryService.page(0, 0, 20, session);
      if (!this.current(request, revision)) { return; }
      this.replace(result.items);
      this.nextMax = result.nextMax; this.nextViewAt = result.nextViewAt; this.noMore = !result.hasMore;
      this.firstLoaded = true; this.dirty = false;
    } catch (e) {
      if (!this.current(request, revision)) { return; }
      this.error = '加载失败，请重试';
    }
    if (this.current(request, revision)) { this.loading = false; this.refreshing = false; }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.noMore || this.loading || !this.firstLoaded || this.session === undefined) { return; }
    const session: HistorySession = this.session;
    const request: number = this.request;
    if (!this.current(request, session.revision)) { return; }
    this.loadingMore = true; this.moreError = ''; this.autoLoadMore = false;
    try {
      const result: HistoryPage = await HistoryService.page(this.nextMax, this.nextViewAt, 20, session);
      if (!this.current(request, session.revision)) { return; }
      this.append(result.items);
      this.nextMax = result.nextMax; this.nextViewAt = result.nextViewAt; this.noMore = !result.hasMore;
    } catch (e) {
      if (!this.current(request, session.revision)) { return; }
      this.moreError = '加载失败，点击重试';
    }
    if (this.current(request, session.revision)) { this.loadingMore = false; }
  }

  private openVideo(item: HistoryItem): void {
    router.pushUrl({ url: 'pages/video/VideoDetailPage', params: {
      'bvid': item.bvid, 'title': item.title, 'cid': item.cid.toString()
    } });
  }

  private openSearch(): void {
    this.searchChild = true;
    router.pushUrl({ url: 'pages/history/HistorySearchPage' }).catch(() => { this.searchChild = false; });
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
    PageTransitionExit({ type: RouteType.Push, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionEnter({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '-33.333333%' })
    PageTransitionExit({ type: RouteType.Pop, duration: NARA_ROUTE_DURATION, curve: NARA_ROUTE_CURVE }).translate({ x: '100%' })
  }

  build() {
    Column() {
      Row() {
        Image($r('app.media.icon_arrow_left')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .onClick(() => { router.back(); }).accessibilityText('返回')
        Text('观看记录').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Blank()
        Image($r('app.media.icon_search')).width(44).height(44).padding(11).fillColor($r('app.color.text_primary'))
          .onClick(() => { this.openSearch(); }).id('history_search').accessibilityText('搜索观看记录')
      }.width('100%').height(56 + this.statusBarH).padding({ top: this.statusBarH, right: 8 })
      if (this.loading && !this.firstLoaded) {
        Column() { LoadingFooter({ text: '正在加载…' }) }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.needLogin) {
        Column({ space: 12 }) {
          Text('登录后可查看观看记录').fontSize(14).fontColor($r('app.color.text_secondary'))
          Button('去登录').fontSize(13).backgroundColor($r('app.color.brand_pink'))
            .onClick(() => { router.pushUrl({ url: 'pages/login/LoginPage' }); })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0 && !this.firstLoaded) {
        Column() { ErrorRetry({ text: this.error, onRetry: () => { this.reload(); } }) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 2, scroller: this.scroller }) {
            if (this.itemCount === 0) {
              ListItem() { EmptyState({ text: this.noMore ? '暂无视频观看记录' : '本页暂无视频观看记录，可继续加载' }) }
            }
            LazyForEach(this.ds, (item: HistoryItem) => {
              ListItem() { HistoryRow({ item: item, onOpen: (used: HistoryItem) => { this.openVideo(used); } }) }
            }, (item: HistoryItem) => item.key)
            ListItem() {
              Column() {
                if (this.error.length > 0) {
                  Text('刷新失败，点击重试').fontSize(12).fontColor($r('app.color.text_secondary'))
                    .onClick(() => { this.reload(true); })
                } else if (this.loadingMore) {
                  LoadingFooter()
                } else {
                  Text(this.moreError.length > 0 ? this.moreError : (this.noMore ? '没有更多了' : '继续加载'))
                    .fontSize(12).fontColor($r('app.color.text_secondary')).padding(16)
                    .onClick(() => { this.loadMore(); })
                }
              }.width('100%').height(100 + this.navBarH).justifyContent(FlexAlign.Center)
            }
          }.width('100%').height('100%').cachedCount(3).scrollBar(BarState.Off).padding({ top: 7 })
            .onReachEnd(() => {
              if (this.autoLoadMore && this.moreError.length === 0 && this.error.length === 0) { this.loadMore(); }
            })
        }.width('100%').layoutWeight(1).onRefreshing(() => { this.reload(true); })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
