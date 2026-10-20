/**
 * 首页 Tab（spec-04 + 样式复刻 Nara）：
 *  - 顶部：搜索栏（高44/圆角25/黑5%）+ 用户头像（34，点击切"我的"）
 *  - 分类：Nara原生15sp文字标签（选中主色/加粗），内容Tabs保留各页位置
 *  - 内容：推荐 / 热门（下拉刷新 + 触底分页）
 */
import { router, uiMaterial, LengthMetrics, curves } from '@kit.ArkUI';
import { thumbUrl } from '../../infra/image/bili_image';
import { BasicDataSource } from '../../common/list_data_source';
import { Pager, PageData } from '../../common/paged_feed';
import { VideoCardGrid } from '../../components/VideoCardGrid';
import { LoadingFooter, ErrorRetry, EmptyState } from '../../components/StateViews';
import { AsyncImage } from '../../components/AsyncImage';
import { FeedCategoryBar } from '../../components/FeedCategoryBar';
import { VideoService, PageResult } from '../../service/video_service';
import { AuthService, UserInfo } from '../../service/auth_service';
import { VideoItem } from '../../model/video_item';
import { FeedNavigation, FeedNavRequest } from '../../common/feed_navigation';

@Component
struct FeedList {
  @Prop source: string = 'rcmd'; // 'rcmd' | 'hot'
  @Prop selected: boolean = false;
  /** 顶部玻璃栏高度：作为首个网格占位，让内容从栏下穿过（沉浸光感） */
  @Prop topInset: number = 0;
  /** 上滑收起顶栏（首行进入视口即收起，与 Nara 一致） */
  onCollapse: (collapsed: boolean) => void = () => {
  };
  /** 自增即滚回顶部（系统返回键回首页时用） */
  @Prop @Watch('onTopTick') topTick: number = 0;
  @Prop @Watch('onNavRequest') navRequest: FeedNavRequest = new FeedNavRequest();
  private navigation: FeedNavigation = new FeedNavigation();
  private ds: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  @State pager: Pager<VideoItem> = new Pager<VideoItem>();
  @State refreshing: boolean = false;
  @State refreshPullOffset: number = 0;
  /** 本地去重：仅在收起状态变化时回调宿主 */
  private collapsedLocal: boolean = false;
  private destroyed: boolean = false;
  private refreshRunning: boolean = false;

  private onNavRequest(): void {
    if (!this.selected || this.destroyed || this.pager.loading || this.refreshRunning) { return; }
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
    this.reload();
  }

  aboutToDisappear(): void { this.destroyed = true; this.pager.cancel(); }

  private async fetchPage(cursor: string): Promise<PageData<VideoItem>> {
    const pn: number = parseInt(cursor, 10);
    const r: PageResult = this.source === 'hot'
      ? await VideoService.hot(pn, 20)
      : await VideoService.rcmd(pn, 20);
    const out: PageData<VideoItem> = {
      items: r.items,
      hasMore: r.hasMore,
      nextCursor: r.nextCursor.toString()
    };
    return out;
  }

  private async reload(): Promise<void> {
    await this.pager.reload(this.ds, (cursor: string): Promise<PageData<VideoItem>> => this.fetchPage(cursor));
  }

  private async refresh(): Promise<void> {
    if (this.destroyed || this.refreshRunning || this.pager.loading) { return; }
    this.refreshRunning = true;
    console.info('[PiliMini-feed] refresh source=' + this.source);
    this.refreshing = true;
    try { await this.reload(); }
    finally {
      this.refreshRunning = false;
      if (!this.destroyed) { this.refreshing = false; }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.destroyed) { return; }
    await this.pager.loadMore(this.ds, (cursor: string): Promise<PageData<VideoItem>> => this.fetchPage(cursor));
  }

  @Builder
  EmptyRefreshIndicator() { Row().width('100%').height(0) }

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
      if (this.pager.loading && !this.pager.firstLoaded) {
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
                .height(this.topInset)
            }
            .columnStart(0)
            .columnEnd(1)

            LazyForEach(this.ds, (item: VideoItem) => {
              GridItem() {
                VideoCardGrid({ model: item })
              }
              .width('100%')
            }, (item: VideoItem) => item.key)

            GridItem() {
              Column() {
                if (this.pager.footerText.length > 0) {
                  Text(this.pager.footerText)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                } else if (this.pager.loadingMore) {
                  LoadingFooter({ text: '加载中…' })
                }
              }
              .width('100%')
              .padding({ top: 20, bottom: 110 })
            }
            .columnStart(0)
            .columnEnd(1)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(12)
          .rowsGap(14)
          .padding({ left: 12, right: 12 })
          .scrollBar(BarState.Off)
          .cachedCount(6)
          .width('100%')
          .height('100%')
          .id('home_feed_' + this.source)
          .onAreaChange((_old: Area, area: Area): void => { this.navigation.viewportHeight = Number(area.height); })
          .onScrollStop((): void => { this.navigation.onScrollStop(); })
          .onScrollIndex((first: number, last: number) => {
            // 首行（占位后的第一排卡片）进入视口 → 收起顶栏（Nara：上滑收起搜索行）
            const collapsed: boolean = first >= 1;
            if (collapsed !== this.collapsedLocal) {
              this.collapsedLocal = collapsed;
              this.onCollapse(collapsed);
            }
            if (last >= this.ds.totalCount() - 4) {
              this.loadMore();
            }
          })
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
  @State mode: number = 0; // 0=推荐 1=热门
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

  private onNavRequest(): void {
    const requests: FeedNavRequest[] = this.feedNavRequests.slice();
    requests[this.mode] = this.navRequest;
    this.feedNavRequests = requests;
  }

  aboutToAppear(): void {
    this.loadUser();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  /** 主壳从其它页面返回（登录态/材质等级可能变化） */
  onShown(): void {
    this.loadUser();
  }

  private async loadUser(): Promise<void> {
    const u: UserInfo | null = await AuthService.fetchNav();
    if (this.destroyed) {
      return;
    }
    if (u !== null) {
      this.loggedIn = true;
      this.face = u.face;
    } else {
      this.loggedIn = false;
      this.face = '';
    }
  }

  /** 顶栏展开/收起高度（含状态栏；搜索行 54 + 分类行 32 + 底部 6） */
  private expandedH(): number {
    return this.statusBarH + 92;
  }

  private collapsedH(): number {
    return this.statusBarH + 40;
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
    .padding({ top: this.statusBarH, bottom: 6 })
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
            selected: this.mode === 0,
            navRequest: this.feedNavRequests[0],
            topInset: this.expandedH(),
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
            selected: this.mode === 1,
            navRequest: this.feedNavRequests[1],
            topInset: this.expandedH(),
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
      .onAnimationEnd((index: number): void => { this.categoryProgress = index; })
      .onChange((index: number) => {
        this.mode = index;
        this.collapsed = this.feedCollapsed[index];
      })

      this.TopBarHost()
    }
    .width('100%')
    .height('100%')
  }
}
