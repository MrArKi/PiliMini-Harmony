/**
 * 首页 Tab（spec-04 + 样式复刻 Nara）：
 *  - 顶部：搜索栏（高44/圆角25/黑5%）+ 用户头像（34，点击切"我的"）
 *  - 分类：Nara原生15sp文字标签（选中主色/加粗），内容Tabs保留各页位置
 *  - 内容：推荐双列竖卡 / 热门单列横卡（下拉刷新 + 触底分页）
 */
import { router, uiMaterial, LengthMetrics, curves } from '@kit.ArkUI';
import { thumbUrl } from '../../infra/image/bili_image';
import { BasicDataSource } from '../../common/list_data_source';
import { Pager, PageData } from '../../common/paged_feed';
import { VideoCardGrid } from '../../components/VideoCardGrid';
import { FeedFilterDialog } from '../../components/FeedFilterDialog';
import { FeedFilterService } from '../../service/feed_filter_service';
import { LoadingFooter, ErrorRetry, EmptyState } from '../../components/StateViews';
import { AsyncImage } from '../../components/AsyncImage';
import { FeedCategoryBar } from '../../components/FeedCategoryBar';
import { VideoService, PageResult } from '../../service/video_service';
import { AuthService, UserInfo } from '../../service/auth_service';
import { VideoItem } from '../../model/video_item';
import { FeedNavigation, FeedNavRequest } from '../../common/feed_navigation';
import { CookieStore } from '../../infra/cookie/cookie_store';
import { HomeCache, HomeCacheScope, HomeSnapshot } from '../../service/home_cache';
import { markStartup } from '../../infra/startup_trace';
import { AppError } from '../../infra/error/app_error';

let snapshotStartupMarked: boolean = false;
let networkStartupMarked: boolean = false;

/** 在临时数据源中完成分页，验证代际后才提交实际列表。 */
class FeedScan {
  added: VideoItem[] = [];
  nextCursor: number = 1;
  hasMore: boolean = true;
  exhausted: boolean = false;
}

@Component
struct FeedList {
  @Prop source: string = 'rcmd'; // 'rcmd' | 'hot'
  /** Tabs 会同时构建两个流；未选中的那个不能先发请求，否则启动就多拉一整页。 */
  @Prop @Watch('onSelected') selected: boolean = false;
  /** 顶部玻璃栏高度：作为首个网格占位，让内容从栏下穿过（沉浸光感） */
  @Prop topInset: number = 0;
  /** 上滑收起顶栏（首行进入视口即收起，与 Nara 一致） */
  onCollapse: (collapsed: boolean) => void = () => {
  };
  onFeedback: (mode: string, item: VideoItem) => void = () => {};
  /** 自增即滚回顶部（系统返回键回首页时用） */
  @Prop @Watch('onTopTick') topTick: number = 0;
  @Prop @Watch('onNavRequest') navRequest: FeedNavRequest = new FeedNavRequest();
  private navigation: FeedNavigation = new FeedNavigation();
  private ds: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>(true);
  private feedVisible: boolean = false;
  private visibleFirst: number = 0;
  private visibleLast: number = -1;
  @State pager: Pager<VideoItem> = new Pager<VideoItem>();
  @State refreshing: boolean = false;
  @State refreshPullOffset: number = 0;
  /** 本地去重：仅在收起状态变化时回调宿主 */
  private collapsedLocal: boolean = false;
  private destroyed: boolean = false;
  private refreshRunning: boolean = false;
  private rawItems: VideoItem[] = [];
  private fetchGeneration: number = 0;
  /** 已成功扫描的推荐高水位；首屏、翻页、刷新沿同一条递增链。 */
  private rcmdNext: number = 1;
  private sessionSeen: Set<string> = new Set<string>();
  private seenOrder: string[] = [];
  private sessionRevision: number = CookieStore.sessionRevision();
  private cacheScope: HomeCacheScope | undefined = undefined;
  private started: boolean = false;
  private bootstrapping: boolean = false;
  private initialNetworkDone: boolean = false;
  private stableCursor: string = '1';
  @State recommendationNotice: string = '';
  @State hiddenPageCount: number = 0;
  @State visibleCount: number = 0;
  private filtersChanged: () => void = (): void => {
    if (!this.destroyed) {
      const items: VideoItem[] = this.rawItems.filter((item: VideoItem): boolean => !FeedFilterService.matches(item));
      this.visibleCount = items.length; this.ds.reload(items);
    }
  };

  private onNavRequest(): void {
    if (!this.selected || this.destroyed || this.bootstrapping || this.pager.loading || this.refreshRunning) { return; }
    if (this.navigation.shouldRefresh(this.navRequest, this.pager.firstLoaded)) { this.refresh(); }
  }

  private onTopTick(): void {
    if (this.topTick <= 0) {
      return;
    }
    try {
      if (this.pager.firstLoaded) { this.navigation.toTop(); }
    } catch (e) {
      // 忽略
    }
    if (this.collapsedLocal) {
      this.collapsedLocal = false;
      this.onCollapse(false);
    }
  }

  aboutToAppear(): void {
    FeedFilterService.subscribe(this.filtersChanged);
    if (this.selected) { this.start(); }
  }

  /** 首次切到该流时才拉第一页（Nara 也是按需首载）。 */
  private onSelected(): void {
    if (this.destroyed) { return; }
    if (!this.selected) {
      // 进入详情时立即冻结源列表；迟到首载不得销毁一镜到底的原卡片。
      if (this.bootstrapping || this.pager.loading || this.pager.loadingMore) {
        this.fetchGeneration++; this.pager.cancel(); this.pager.cursor = this.stableCursor;
        if (this.bootstrapping) { this.started = false; }
        this.bootstrapping = false; this.initialNetworkDone = false;
        this.refreshRunning = false; this.refreshing = false;
      }
      return;
    }
    if (this.sessionRevision !== CookieStore.sessionRevision()) { this.restartSession(); return; }
    if (!this.started) { this.start(); }
    else if (!this.bootstrapping && !this.pager.loading && (!this.initialNetworkDone || !this.pager.firstLoaded)) { this.reload(); }
    else { this.checkAfterLayout(); }
  }

  aboutToDisappear(): void {
    this.destroyed = true; this.fetchGeneration++; this.pager.cancel(); FeedFilterService.unsubscribe(this.filtersChanged);
    this.rawItems = [];
  }

  private valid(generation: number, revision: number): boolean {
    return !this.destroyed && generation === this.fetchGeneration && revision === CookieStore.sessionRevision();
  }

  private restartSession(): void {
    this.fetchGeneration++; this.pager.cancel();
    this.sessionRevision = CookieStore.sessionRevision();
    this.rawItems = []; this.ds.reload([]); this.visibleCount = 0;
    this.sessionSeen.clear(); this.seenOrder = []; this.rcmdNext = 1;
    this.cacheScope = undefined; this.started = false; this.bootstrapping = false;
    this.refreshRunning = false; this.refreshing = false;
    this.initialNetworkDone = false; this.pager.firstLoaded = false;
    this.stableCursor = '1';
    this.pager.hasMore = true; this.pager.cursor = '1'; this.pager.error = ''; this.pager.footerText = '';
    this.recommendationNotice = ''; this.hiddenPageCount = 0;
    if (this.selected && !this.destroyed) { this.start(); }
  }

  private remember(items: VideoItem[]): void {
    for (let i: number = 0; i < items.length; i++) {
      const bvid: string = items[i].bvid;
      if (this.sessionSeen.has(bvid)) { continue; }
      this.sessionSeen.add(bvid); this.seenOrder.push(bvid);
      if (this.seenOrder.length > 600) { this.sessionSeen.delete(this.seenOrder.shift() || ''); }
    }
  }

  /** 本地快照不阻塞主壳；未选中流只读本地，不发推荐请求。 */
  private async start(): Promise<void> {
    if (this.started || this.destroyed) { return; }
    this.started = true; this.bootstrapping = true; this.pager.loading = true;
    const generation: number = this.fetchGeneration;
    const revision: number = this.sessionRevision;
    try {
      await FeedFilterService.ready();
      if (this.source !== 'hot') {
        const scope: HomeCacheScope | undefined = await HomeCache.scope(revision);
        const snapshot: HomeSnapshot | undefined = scope !== undefined ? await HomeCache.read(scope) : undefined;
        if (!this.valid(generation, revision)) { return; }
        this.cacheScope = scope;
        if (snapshot !== undefined) {
          this.rawItems = snapshot.items; this.rcmdNext = snapshot.nextCursor;
          this.remember(snapshot.items); this.pager.cursor = snapshot.nextCursor.toString();
          this.stableCursor = this.pager.cursor;
          this.pager.firstLoaded = true; this.filtersChanged();
          if (!snapshotStartupMarked) { snapshotStartupMarked = true; markStartup('homeSnapshotReady'); }
        }
      }
    } catch (_) {
      // 快照与屏蔽存储暂不可用时仍可进入正常请求错误/重试路径。
    } finally {
      if (this.valid(generation, revision)) {
        this.bootstrapping = false; this.pager.loading = false;
        if (this.selected) { this.reload(); }
      } else if (!this.destroyed && this.sessionRevision !== CookieStore.sessionRevision()) { this.restartSession(); }
    }
  }

  private async fetchPage(cursor: string, generation: number, revision: number,
    replace: boolean, scan: FeedScan): Promise<PageData<VideoItem>> {
    await FeedFilterService.ready();
    const seen: Set<string> = new Set<string>();
    if (!replace || this.source !== 'hot') {
      this.rawItems.forEach((item: VideoItem): void => { seen.add(item.bvid); });
    }
    let pn: number = parseInt(cursor, 10);
    const limit: number = this.source === 'hot' ? 1 : 3;
    for (let page: number = 0; page < limit; page++) {
      if (!this.valid(generation, revision)) { throw new Error('推荐请求已失效'); }
      if (page > 0 && !this.selected) { throw new Error('推荐流已切到后台'); }
      const r: PageResult = this.source === 'hot'
        ? await VideoService.hot(pn, 20) : await VideoService.rcmd(pn, 12);
      if (!this.valid(generation, revision)) { throw new Error('推荐请求已失效'); }
      for (let i: number = 0; i < r.items.length; i++) {
        const item: VideoItem = r.items[i];
        if (item.bvid.length === 0 || seen.has(item.bvid) ||
          (this.source !== 'hot' && this.sessionSeen.has(item.bvid))) { continue; }
        seen.add(item.bvid); scan.added.push(item);
      }
      scan.nextCursor = this.source === 'hot' ? r.nextCursor : Math.max(pn + 1, r.nextCursor);
      scan.hasMore = r.hasMore && scan.nextCursor !== pn;
      const visible: VideoItem[] = scan.added.filter((item: VideoItem): boolean => !FeedFilterService.matches(item));
      if (visible.length > 0 || this.source === 'hot') {
        return { items: visible, hasMore: scan.hasMore, nextCursor: scan.nextCursor.toString() };
      }
      if (!scan.hasMore) { break; }
      pn = scan.nextCursor;
    }
    // 网络成功但没有新可见视频：不能把刷新误报成功，也不能回填旧推荐。
    scan.exhausted = true;
    throw new Error('暂时没有新推荐');
  }

  private saveSnapshot(): void {
    if (this.source !== 'hot' && this.cacheScope !== undefined) {
      HomeCache.save(this.cacheScope, this.rawItems.filter((item: VideoItem): boolean =>
        !FeedFilterService.matches(item)), this.rcmdNext);
    }
  }

  private accept(scan: FeedScan, replace: boolean): void {
    this.rawItems = replace ? scan.added : this.rawItems.concat(scan.added);
    if (this.source !== 'hot') { this.rcmdNext = scan.nextCursor; this.remember(scan.added); }
    this.hiddenPageCount = scan.added.some((item: VideoItem): boolean => !FeedFilterService.matches(item))
      ? 0 : this.hiddenPageCount + 1;
    const visible: VideoItem[] = this.rawItems.filter((item: VideoItem): boolean => !FeedFilterService.matches(item));
    this.visibleCount = visible.length;
    this.stableCursor = this.pager.cursor;
    if (replace) { this.ds.reload(visible); }
    else { this.ds.append(scan.added.filter((item: VideoItem): boolean => !FeedFilterService.matches(item))); }
    this.recommendationNotice = ''; this.saveSnapshot();
    if (this.source !== 'hot' && !networkStartupMarked) {
      networkStartupMarked = true; markStartup('homeNetworkReady');
    }
  }

  private exhausted(scan: FeedScan): void {
    this.rcmdNext = scan.nextCursor; this.pager.cursor = scan.nextCursor.toString();
    this.pager.hasMore = scan.hasMore; this.pager.firstLoaded = true; this.pager.error = '';
    this.stableCursor = this.pager.cursor;
    this.hiddenPageCount = 3;
    this.recommendationNotice = this.rawItems.length > 0
      ? '暂时没有新推荐，已保留当前列表' : '暂时没有可展示的新推荐';
    this.pager.footerText = this.recommendationNotice;
    this.saveSnapshot();
  }

  private async reload(): Promise<void> {
    if (this.destroyed || !this.selected || this.bootstrapping || this.pager.loading) { return; }
    if (this.sessionRevision !== CookieStore.sessionRevision()) { this.restartSession(); return; }
    const oldCursor: string = this.pager.cursor;
    this.pager.initialCursor = this.source === 'hot' ? '1' : this.rcmdNext.toString();
    const generation: number = ++this.fetchGeneration;
    const revision: number = this.sessionRevision;
    const scan: FeedScan = new FeedScan();
    const staged: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
    this.initialNetworkDone = true;
    const accepted: boolean = await this.pager.reload(staged, (cursor: string): Promise<PageData<VideoItem>> =>
      this.fetchPage(cursor, generation, revision, true, scan));
    if (!this.valid(generation, revision)) {
      if (!this.destroyed && this.sessionRevision !== CookieStore.sessionRevision()) { this.restartSession(); }
      return;
    }
    if (accepted) { this.accept(scan, true); this.checkAfterLayout(); }
    else if (scan.exhausted) { this.exhausted(scan); }
    else { this.pager.cursor = oldCursor; }
  }

  private async refresh(): Promise<void> {
    if (this.destroyed || !this.selected || this.bootstrapping || this.refreshRunning || this.pager.loading) { return; }
    this.refreshRunning = true; this.refreshing = true;
    const generation: number = this.fetchGeneration + 1;
    try { await this.reload(); }
    finally {
      if (!this.destroyed && generation === this.fetchGeneration) {
        this.refreshRunning = false; this.refreshing = false;
        this.checkAfterLayout();
      }
    }
  }

  private async loadMore(automatic: boolean = false): Promise<void> {
    if (this.destroyed || !this.selected || this.bootstrapping || this.refreshRunning || this.pager.loading || this.pager.loadingMore ||
      !this.pager.hasMore || !this.pager.firstLoaded ||
      (automatic && (!this.feedVisible || this.pager.lastError.length > 0 || this.hiddenPageCount >= 3))) { return; }
    if (this.sessionRevision !== CookieStore.sessionRevision()) { this.restartSession(); return; }
    const generation: number = this.fetchGeneration;
    const revision: number = this.sessionRevision;
    const scan: FeedScan = new FeedScan();
    const staged: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
    const accepted: boolean = await this.pager.loadMore(staged, (cursor: string): Promise<PageData<VideoItem>> =>
      this.fetchPage(cursor, generation, revision, false, scan));
    if (!this.valid(generation, revision)) {
      if (!this.destroyed && this.sessionRevision !== CookieStore.sessionRevision()) { this.restartSession(); }
      return;
    }
    if (accepted) { this.accept(scan, false); this.checkAfterLayout(); }
    else if (scan.exhausted) { this.exhausted(scan); }
  }

  private prefetchVisible(): void {
    if (this.ds.size() === 0) { return; }
    let atEnd: boolean = false;
    try { atEnd = this.navigation.scroller.isAtEnd(); } catch (_) {}
    if (atEnd) { this.loadMore(true); return; }
    if (this.visibleLast < 0) { return; }
    const ahead: number = Math.max(this.source === 'hot' ? 3 : 6, this.visibleLast - this.visibleFirst + 1);
    // Grid首项是跨列顶栏占位，最后一条卡片索引等于数据源大小。
    if (this.ds.size() - this.visibleLast <= ahead) { this.loadMore(true); }
  }

  private checkAfterLayout(): void {
    if (this.destroyed || !this.selected) { return; }
    this.navigation.afterLayout(this.getUIContext(), (): void => { this.prefetchVisible(); });
  }

  @Builder
  EmptyRefreshIndicator() { Row().width('100%').height(0) }

  /** Nara HotPage 的横卡骨架：首载从第一帧保留列表几何，不先显示空态。 */
  @Builder
  HotInitialSkeleton() {
    Column() {
      Column().width('100%').height(this.topInset + 7)
      ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], (index: number) => {
        Row({ space: 10 }) {
          Column().width(160).height(100).borderRadius(10)
            .backgroundColor($r('app.color.btn_soft_bg'))
          Column({ space: 5 }) {
            Column().width('100%').height(13).backgroundColor($r('app.color.btn_soft_bg'))
            Column().width('75%').height(13).backgroundColor($r('app.color.btn_soft_bg'))
            Blank()
            Column().width('60%').height(13).backgroundColor($r('app.color.btn_soft_bg'))
            Row({ space: 8 }) {
              Column().width(40).height(13).backgroundColor($r('app.color.btn_soft_bg'))
              Column().width(40).height(13).backgroundColor($r('app.color.btn_soft_bg'))
            }.width('100%')
          }.layoutWeight(1).height(100).padding({ top: 4, bottom: 4, right: 6 })
            .alignItems(HorizontalAlign.Start)
        }.width('100%').height(110).padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .margin({ bottom: 2 })
      }, (index: number) => index.toString())
    }.width('100%').height('100%').clip(true).alignItems(HorizontalAlign.Start)
      .accessibilityText('热门正在加载').id('home_hot_initial_skeleton')
  }

  /** 原生Refresh推进卡片；圆环在顶栏下方新增的下拉空白内居中。 */
  @Builder
  FeedRefreshIndicator() {
    Row() {
      LoadingProgress().width(28).height(28).color($r('app.color.brand_pink'))
    }
    .width(49).height(49).justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.card_bg')).borderRadius(24.5)
    .shadow({ radius: 2, color: '#33000000', offsetY: 2 })
    .position({ x: '50%', y: this.topInset + this.refreshPullOffset / 2 - 24.5 })
    .translate({ x: -24.5 })
    .scale({ x: Math.min(1, this.refreshPullOffset / 64),
      y: Math.min(1, this.refreshPullOffset / 64) })
    .hitTestBehavior(HitTestMode.None)
    .accessibilityText('正在刷新')
  }

  build() {
    Column() {
      if (this.source === 'hot' && !this.pager.firstLoaded && this.pager.error.length === 0) {
        this.HotInitialSkeleton()
      } else if (this.pager.loading && !this.pager.firstLoaded) {
        Column() {
          LoadingFooter({ text: '正在加载…' })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.pager.error.length > 0 && !this.pager.firstLoaded) {
        Column() {
          ErrorRetry({
            text: this.pager.error,
            onRetry: () => {
              this.reload();
            }
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Stack({ alignContent: Alignment.Top }) {
        Refresh({ refreshing: $$this.refreshing, builder: this.EmptyRefreshIndicator() }) {
          Grid(this.navigation.scroller) {
            GridItem() {
              Column()
                .width('100%')
                .height(this.topInset + (this.source === 'hot' ? 5 : 0))
            }
            .columnStart(0)
            .columnEnd(this.source === 'hot' ? 0 : 1)

            LazyForEach(this.ds, (item: VideoItem) => {
              GridItem() {
                VideoCardGrid({ model: item, horizontal: this.source === 'hot', onFeedback: this.onFeedback })
              }
              .width('100%')
            }, (item: VideoItem) => item.key)

            GridItem() {
              Column() {
                if (this.visibleCount === 0 && this.recommendationNotice.length === 0 && !this.pager.loadingMore) {
                  Text('暂无可展示内容，可在屏蔽管理中解除规则')
                    .fontSize(12).fontColor($r('app.color.text_secondary')).margin({ bottom: 12 })
                }
                if ((this.visibleCount === 0 || this.hiddenPageCount >= 3) && this.pager.hasMore &&
                  !this.pager.loading && !this.pager.loadingMore) {
                  Button('继续加载', { type: ButtonType.Normal }).fontSize(13)
                    .fontColor($r('app.color.brand_pink')).backgroundColor(Color.Transparent)
                    .height(40).onClick(() => { this.hiddenPageCount = 0; this.loadMore(); })
                }
                if (this.pager.footerText.length > 0) {
                  Text(this.pager.footerText)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .onClick(() => { if (this.pager.lastError.length > 0) { this.loadMore(); } })
                } else if (this.pager.loadingMore) {
                  LoadingFooter({ text: '加载中…' })
                }
              }
              .width('100%')
              .padding({ top: 20, bottom: 110 })
            }
            .columnStart(0)
            .columnEnd(this.source === 'hot' ? 0 : 1)
          }
          .columnsTemplate(this.source === 'hot' ? '1fr' : '1fr 1fr')
          .columnsGap(this.source === 'hot' ? 0 : 8)
          .rowsGap(this.source === 'hot' ? 2 : 8)
          .padding({ left: this.source === 'hot' ? 0 : 12, right: this.source === 'hot' ? 0 : 12 })
          .scrollBar(BarState.Off)
          .cachedCount(2)
          .width('100%')
          .height('100%')
          .id('home_feed_' + this.source)
          .backToTop(this.selected)
          .onAreaChange((_old: Area, area: Area): void => {
            this.navigation.viewportHeight = Number(area.height); this.checkAfterLayout();
          })
          .onScrollStop((): void => { this.navigation.onScrollStop(); })
          .onVisibleAreaChange([0], (visible: boolean): void => {
            this.feedVisible = visible;
            if (visible) { this.checkAfterLayout(); }
          })
          .onScrollIndex((first: number, last: number) => {
            // 首行（占位后的第一排卡片）进入视口 → 收起顶栏（Nara：上滑收起搜索行）
            const collapsed: boolean = first >= 1;
            if (collapsed !== this.collapsedLocal) {
              this.collapsedLocal = collapsed;
              this.onCollapse(collapsed);
            }
            this.visibleFirst = first; this.visibleLast = last;
            this.prefetchVisible();
          })
          .onReachEnd((): void => { this.loadMore(true); })
        }
        .refreshOffset(64)
        .onOffsetChange((offset: number): void => { this.refreshPullOffset = Math.max(0, offset); })
        .onRefreshing(() => {
          this.refresh();
        })
        .height('100%')
        .width('100%')
        if (this.refreshPullOffset > 0) { this.FeedRefreshIndicator() }
        }.layoutWeight(1).width('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Component
export struct HomeTab {
  @Prop active: boolean = true;
  @State mode: number = 0; // 0=推荐 1=热门
  /** 滑动确定目标时放行首载，Tabs索引仍由实际切换回调维护。 */
  @State requestMode: number = 0;
  @State categoryProgress: number = 0;
  private feedTabs: TabsController = new TabsController();
  private feedCollapsed: boolean[] = [false, false];
  @State face: string = '';
  @State loggedIn: boolean = false;
  @Prop @Watch('onShown') refreshTick: number = 0;
  /** 自增即回顶部（系统返回键回首页） */
  @Prop topTick: number = 0;
  @Prop @Watch('onNavRequest') navRequest: FeedNavRequest = new FeedNavRequest();
  @State feedNavRequests: FeedNavRequest[] = [new FeedNavRequest(), new FeedNavRequest()];
  @StorageProp('statusBarHeight') statusBarH: number = 0;
  /** 顶栏是否已上滑收起（搜索行淡出、只留分类行） */
  @State collapsed: boolean = false;
  /** 全屏等场景隐藏顶栏 */
  @State isFullscreenHidden: boolean = false;
  onGoMine: () => void = () => {
  };
  private destroyed: boolean = false;
  private feedbackDialog: CustomDialogController | undefined = undefined;
  private userRequest: number = 0;
  private userSessionRevision: number = CookieStore.sessionRevision();

  private openFeedback(mode: string, item: VideoItem | undefined = undefined): void {
    if (this.destroyed) { return; }
    if (this.feedbackDialog !== undefined) { this.feedbackDialog.close(); }
    this.feedbackDialog = new CustomDialogController({
      builder: FeedFilterDialog({ mode: mode, model: item }), customStyle: true,
      alignment: DialogAlignment.Center, autoCancel: true
    });
    this.feedbackDialog.open();
  }

  private onNavRequest(): void {
    const requests: FeedNavRequest[] = this.feedNavRequests.slice();
    requests[this.mode] = this.navRequest;
    this.feedNavRequests = requests;
  }

  aboutToAppear(): void {
    this.destroyed = false;
    this.loadUser().catch((): void => { console.warn('[PiliMini-home] user refresh unavailable'); });
    FeedFilterService.refreshSessionBlocks().catch((): void => {});
  }

  aboutToDisappear(): void {
    this.destroyed = true; this.userRequest++;
    if (this.feedbackDialog !== undefined) { this.feedbackDialog.close(); this.feedbackDialog = undefined; }
  }

  /** 主壳从其它页面返回（登录态/材质等级可能变化） */
  onShown(): void {
    this.loadUser().catch((): void => { console.warn('[PiliMini-home] user refresh unavailable'); });
    FeedFilterService.refreshSessionBlocks().catch((): void => {});
  }

  private async loadUser(): Promise<void> {
    const request: number = ++this.userRequest;
    const revision: number = CookieStore.sessionRevision();
    const current: () => boolean = (): boolean => !this.destroyed && request === this.userRequest &&
      revision === CookieStore.sessionRevision();
    if (!current()) { return; }
    if (this.userSessionRevision !== revision) {
      this.userSessionRevision = revision; this.loggedIn = false; this.face = '';
    }
    try {
      // 本地展示先行；网络失败保留同一会话资料，不能误当作退出登录。
      if (!this.loggedIn) {
        const cached: UserInfo | null = await AuthService.cachedUser();
        if (!current()) { return; }
        if (cached !== null) { this.loggedIn = true; this.face = cached.face; }
      }
      const u: UserInfo | null = await AuthService.fetchNav(true);
      if (!current()) { return; }
      this.loggedIn = u !== null; this.face = u !== null ? u.face : '';
    } catch (e) {
      if (!current()) { return; }
      const err: AppError = e as AppError;
      if (err !== null && err !== undefined && err.type === 'auth') {
        // fetchNav已通过ensureOk触发-101全局登出，不能保留已失效的账号展示。
        this.loggedIn = false; this.face = '';
      }
      console.warn('[PiliMini-home] user refresh unavailable');
    }
  }

  /** Nara搜索行54、分类32；列表留白另按NativeTopSpacer的85计算。 */
  private expandedH(): number {
    return this.statusBarH + 86;
  }

  private collapsedH(): number {
    return this.statusBarH + 32;
  }

  private feedTopInset(): number {
    return this.statusBarH + 85;
  }

  /** 顶栏玻璃底（Nara：linearGradient 蒙版 + linearGradientBlur 15，渐变方向 Bottom→Top） */
  @Builder
  TopBarBackdrop() {
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          [$r('app.color.top_bar_mask_start'), 0],
          [$r('app.color.top_bar_mask_mid'), 0.8],
          [$r('app.color.top_bar_mask_end'), 0.95],
          [$r('app.color.top_bar_mask_end'), 1]
        ]
      })
      .linearGradientBlur(15, {
        fractionStops: [[0, 0], [0.8, 0.2], [1, 0.4], [1, 1]],
        direction: GradientDirection.Top
      })
      .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 顶栏第一行：搜索胶囊 + 头像（各元素挂官方沉浸式系统材质） */
  @Builder
  TopBar() {
    Row({ space: 8 }) {
      Row({ space: 10 }) {
        Image($r('app.media.icon_search'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.brand_pink'))
        Text('搜索视频')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
        Blank()
      }
      .layoutWeight(1)
      .height(44)
      .padding({ left: 14 })
      .borderRadius(22)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true,
        lightEffect: {}
      }))
      .onClick(() => {
        router.pushUrl({ url: 'pages/search/SearchPage' });
      })

      Column() {
        if (this.loggedIn && this.face.length > 0) {
          AsyncImage({ src: thumbUrl(this.face, 96, 96), w: 96, h: 96 })
        } else {
          Image($r('app.media.icon_person'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.brand_pink'))
        }
      }
      .width(41)
      .height(41)
      .borderRadius(20.5)
      .clip(true)
      .justifyContent(FlexAlign.Center)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true,
        lightEffect: {}
      }))
      .onClick(() => {
        this.onGoMine();
      })
    }
    .width('100%')
    .height(this.collapsed ? 0 : 54)
    .padding({ left: 14, right: 14, top: this.collapsed ? 0 : 5, bottom: this.collapsed ? 0 : 5 })
    .clip(true)
    .opacity(this.collapsed ? 0 : 1)
    .animation({ duration: 300, curve: curves.cubicBezierCurve(0.2, 0, 0, 1) })
  }

  /** 顶栏第二行：推荐 / 热门（收起时保留） */
  @Builder
  ChipsBar() {
    FeedCategoryBar({ labels: ['推荐', '热门'], selected: this.mode, progress: this.categoryProgress,
      onSelect: (index: number): void => { this.feedTabs.changeIndex(index); } })
  }

  /** 顶栏内容（放在 Navigation 自定义标题里） */
  @Builder
  TopBarContent() {
    Column() {
      this.TopBar()
      this.ChipsBar()
    }
    .width('100%')
    .padding({ top: this.statusBarH })
  }

  /** 顶栏宿主：透明 Navigation（空内容、STACK、显式高度）+ 渐变模糊底；上滑收起 */
  @Builder
  TopBarHost() {
    Stack({ alignContent: Alignment.Top }) {
      this.TopBarBackdrop()
      Navigation() {
        // 空内容区：STACK 下被标题栏完全覆盖，且不参与触摸测试（触摸透传到下方列表）
        Column()
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
      }
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .title({ builder: this.TopBarContent(), height: this.expandedH() }, {
        barStyle: BarStyle.STACK,
        paddingStart: LengthMetrics.vp(0),
        paddingEnd: LengthMetrics.vp(0)
      })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height(this.expandedH())
    }
    .width('100%')
    .height(this.collapsed ? this.collapsedH() : this.expandedH())
    .clip(true)
    .animation({ duration: 300, curve: curves.cubicBezierCurve(0.2, 0, 0, 1) })
    .visibility(this.isFullscreenHidden ? Visibility.None : Visibility.Visible)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Tabs({ index: this.mode, controller: this.feedTabs }) {
        TabContent() {
          FeedList({
            source: 'rcmd',
            onFeedback: (mode: string, item: VideoItem): void => { this.openFeedback(mode, item); },
            selected: this.active && this.requestMode === 0,
            navRequest: this.feedNavRequests[0],
            topInset: this.feedTopInset(),
            topTick: this.topTick,
            onCollapse: (c: boolean) => {
              this.feedCollapsed[0] = c;
              if (this.mode === 0) { this.collapsed = c; }
            }
          })
        }
        TabContent() {
          FeedList({
            source: 'hot',
            onFeedback: (mode: string, item: VideoItem): void => { this.openFeedback(mode, item); },
            selected: this.active && this.requestMode === 1,
            navRequest: this.feedNavRequests[1],
            topInset: this.feedTopInset(),
            topTick: this.topTick,
            onCollapse: (c: boolean) => {
              this.feedCollapsed[1] = c;
              if (this.mode === 1) { this.collapsed = c; }
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .barHeight(0)
      .animationDuration(300)
      .onContentDidScroll((_selected: number, index: number, position: number): void => {
        this.categoryProgress = Math.max(0, Math.min(1, index - position));
      })
      .onAnimationStart((_index: number, targetIndex: number): void => {
        this.requestMode = targetIndex;
      })
      .onAnimationEnd((index: number): void => {
        this.categoryProgress = index;
        this.requestMode = index;
      })
      .onChange((index: number) => {
        this.mode = index;
        this.requestMode = index;
        this.collapsed = this.feedCollapsed[index];
      })

      this.TopBarHost()
    }
    .width('100%')
    .height('100%')
  }
}
